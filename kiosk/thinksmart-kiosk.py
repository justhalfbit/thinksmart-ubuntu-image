#!/usr/bin/env python3
"""Full-screen single-page browser for the ThinkSmart kiosk session (runs inside Weston).

Reads URL= from /etc/thinksmart-kiosk.conf. Cookies and site data persist in
~/.local/share/thinksmart-kiosk so logins survive reboots.

While the URL can't be loaded (nothing installed there yet, the service is starting or
was removed, no network) the built-in welcome page is shown instead of WebKit's error
page, and the URL is retried in the background until it answers. A device that has never
been on a network (fresh image: no saved Wi-Fi, no address) also stays on the welcome page,
where Wi-Fi is set up on the screen, even though the local voice client would load.

Every page gets the on-screen keyboard (keyboard.js, injected): it slides up whenever a text field
has focus, so pages only use plain <input>s. The welcome page and the configured page, when that is
served by this device itself (127.0.0.1/localhost: the voice client's settings), may ask us to scan
for and join Wi-Fi networks through window.webkit.messageHandlers.thinksmart.
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import gi

gi.require_version('Gtk', '3.0')
gi.require_version('WebKit2', '4.1')
from gi.repository import GLib, Gtk, WebKit2  # noqa: E402

CONF = '/etc/thinksmart-kiosk.conf'
SHARE = '/usr/local/share/thinksmart-kiosk'
WELCOME = SHARE + '/welcome.html'
KEYBOARD = SHARE + '/keyboard.js'
RETRY_SECONDS = 5


def read_conf():
    conf = {}
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                conf[key.strip()] = value.strip().strip('"\'')
    except OSError:
        pass
    return conf


def device_status():
    """What the welcome page shows about the device: addresses, host name, Wi-Fi."""
    addrs = []
    try:
        out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'scope', 'global'],
                             capture_output=True, text=True, timeout=2).stdout
        addrs = [(line.split()[1], line.split()[3].split('/')[0]) for line in out.splitlines()]
    except (OSError, subprocess.SubprocessError, IndexError):
        pass
    # usb0 is the USB-cable network (the computer on the other end gets 172.16.42.2); it is
    # always up, so it doesn't mean the device is online and is shown only as a rescue hint
    ips = [ip for iface, ip in addrs if not iface.startswith('usb')]
    usb = next((ip for iface, ip in addrs if iface.startswith('usb')), '')
    ssid = ''
    try:
        out = subprocess.run(['nmcli', '-t', '-f', 'ACTIVE,SSID', 'dev', 'wifi'],
                             capture_output=True, text=True, timeout=2).stdout
        ssid = next((line[4:] for line in out.splitlines() if line.startswith('yes:')), '')
    except (OSError, subprocess.SubprocessError):
        pass
    return {'ip': ','.join(ips), 'usb': usb, 'host': socket.gethostname(), 'ssid': ssid}


def nmcli(*args, timeout=10):
    return subprocess.run(['nmcli', *args], capture_output=True, text=True, timeout=timeout)


def nmcli_fields(line):
    """Split one line of `nmcli -t` output (':' separated, '\\:' escaped)."""
    return [f.replace('\\:', ':').replace('\\\\', '\\') for f in re.split(r'(?<!\\):', line)]


def connection_uuids(active=False):
    out = nmcli('-t', '-f', 'UUID,TYPE', 'connection', 'show', *(['--active'] if active else [])).stdout
    return {f[0]: f[1] for f in map(nmcli_fields, out.splitlines()) if len(f) >= 2}


def wifi_profiles():
    """Saved Wi-Fi networks (NetworkManager keeps their passwords): SSID -> profile UUID."""
    profiles = {}
    for uuid, kind in connection_uuids().items():
        if kind == '802-11-wireless':
            ssid = nmcli('-g', '802-11-wireless.ssid', 'connection', 'show', 'uuid', uuid).stdout.strip()
            if ssid:
                profiles[nmcli_fields(ssid)[0]] = uuid
    return profiles


def needs_network_setup():
    """Fresh device: no saved Wi-Fi network and no address on any other interface (USB aside)."""
    try:
        return not device_status()['ip'] and not wifi_profiles()
    except (OSError, subprocess.SubprocessError):
        return False


def wifi_status(_msg, _progress):
    """The network Wi-Fi is on now (empty ssid: none), for the client's settings page."""
    try:
        out = nmcli('-t', '-f', 'ACTIVE,SSID,SIGNAL', 'dev', 'wifi', 'list', '--rescan', 'no', timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {'ok': False}
    for f in map(nmcli_fields, out.splitlines()):
        if len(f) >= 3 and f[0] == 'yes':
            return {'ok': True, 'ssid': f[1], 'signal': int(f[2] or 0)}
    return {'ok': True, 'ssid': '', 'signal': 0}


def wifi_scan(_msg, _progress):
    try:
        out = nmcli('-t', '-f', 'IN-USE,SSID,SIGNAL,SECURITY', 'dev', 'wifi', 'list', '--rescan', 'yes',
                    timeout=25).stdout
        saved = wifi_profiles()
    except (OSError, subprocess.SubprocessError):
        return {'ok': False}
    best = {}  # one entry per SSID: the connected one, else the strongest access point
    for line in out.splitlines():
        f = nmcli_fields(line)
        if len(f) < 4 or not f[1]:
            continue
        n = {'ssid': f[1], 'signal': int(f[2] or 0), 'secure': f[3] not in ('', '--'),
             'active': f[0] == '*', 'saved': f[1] in saved}
        old = best.get(n['ssid'])
        if old is None or n['active'] or (not old['active'] and n['signal'] > old['signal']):
            best[n['ssid']] = n
    return {'ok': True, 'networks': sorted(best.values(), key=lambda n: (not n['active'], not n['saved'], -n['signal']))}


def reconnect_later(uuid):
    """After a failed attempt, bring the previous network back without making the user wait for it."""
    def work():
        try:
            nmcli('connection', 'up', 'uuid', uuid, timeout=45)
        except (OSError, subprocess.SubprocessError):
            pass
    threading.Thread(target=work, daemon=True).start()


def supplicant_state(path):
    """wpa_supplicant's state for wlan0 (scanning, associating, 4way_handshake, completed, ...)."""
    try:
        out = subprocess.run(['busctl', 'get-property', 'fi.w1.wpa_supplicant1', path,
                              'fi.w1.wpa_supplicant1.Interface', 'State'],
                             capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ''
    return out.split('"')[1] if out.count('"') >= 2 else ''


def supplicant_path():
    try:
        out = subprocess.run(['busctl', 'call', 'fi.w1.wpa_supplicant1', '/fi/w1/wpa_supplicant1',
                              'fi.w1.wpa_supplicant1', 'GetInterface', 's', 'wlan0'],
                             capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ''
    return out.split('"')[1] if out.count('"') >= 2 else ''


# A good password finishes the 4-way handshake in ~0.1 s (17 joins on this device: median 0.10 s,
# slowest 0.83 s); with a wrong one wpa_supplicant waits 10 s before giving up. Access points
# resend a lost handshake frame about once a second and give up after ~4 tries, so a handshake
# still stuck after 5 s won't succeed whatever the signal: call it a wrong password then.
HANDSHAKE_GIVE_UP = 5.0
STAGES = {'scanning': 'scan', 'authenticating': 'join', 'associating': 'join', 'associated': 'join',
          '4way_handshake': 'auth', 'group_handshake': 'auth', 'completed': 'ip'}


def run_nmcli_watched(cmd, progress):
    """Run an nmcli activation while reporting wpa_supplicant's stages through progress(stage).

    Returns (ok, error text). Stops early once the handshake hangs (wrong password).
    """
    path = supplicant_path()
    p = subprocess.Popen(['nmcli', *cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 50
    stage = handshake_since = None
    left_old = False  # 'completed' only counts once the old network has been dropped
    while p.poll() is None:
        state = supplicant_state(path) if path else ''
        left_old = left_old or (state not in ('', 'completed'))
        new_stage = STAGES.get(state) if left_old else None
        if new_stage and new_stage != stage:
            stage = new_stage
            progress(stage)
        if state in ('4way_handshake', 'group_handshake'):
            handshake_since = handshake_since or time.monotonic()
            if time.monotonic() - handshake_since > HANDSHAKE_GIVE_UP:
                break
        else:
            handshake_since = None
        if time.monotonic() > deadline:
            break
        time.sleep(0.25)
    if p.poll() is None:
        wrong = handshake_since is not None
        p.terminate()
        nmcli('device', 'disconnect', 'wlan0')  # stop the activation NetworkManager is still running
        return False, 'Secrets were required' if wrong else 'Timeout'
    out, err = p.communicate()
    return p.returncode == 0, (err or out).strip()


def wifi_connect(msg, progress):
    """Join a network: with the saved password when no new one is given, else with the new one."""
    ssid, password = str(msg.get('ssid') or ''), str(msg.get('password') or '')
    if not 0 < len(ssid.encode()) <= 32 or (password and not 8 <= len(password) <= 63):
        return {'ok': False, 'reason': 'invalid'}
    before = connection_uuids()
    previous = next((u for u, t in connection_uuids(active=True).items() if t == '802-11-wireless'), None)
    saved = wifi_profiles().get(ssid)
    # `dev wifi connect` writes a typed password into the saved profile; keep the old one so a
    # typo doesn't cost the network that was working
    old_psk = None
    if saved and password:
        old_psk = nmcli('-s', '-g', '802-11-wireless-security.psk', 'connection', 'show', 'uuid', saved).stdout.strip()
    if saved and not password and not msg.get('hidden'):
        cmd = ['--wait', '40', 'connection', 'up', 'uuid', saved]
    else:
        cmd = ['--wait', '40', 'dev', 'wifi', 'connect', ssid]
        if password:
            cmd += ['password', password]
        if msg.get('hidden'):
            cmd += ['hidden', 'yes']
    ok, err = run_nmcli_watched(cmd, progress)
    if ok:
        return {'ok': True}
    reason =('password' if 'Secrets were required' in err or 'no-secrets' in err or 'password' in err.lower() else
              'notfound' if 'No network with SSID' in err else
              'timeout' if 'Timeout' in err or 'timed out' in err else 'failed')
    # Don't keep a new profile with a wrong password around; put a saved one's password back
    for uuid in set(connection_uuids()) - set(before):
        nmcli('connection', 'delete', 'uuid', uuid)
    if old_psk:
        nmcli('connection', 'modify', 'uuid', saved, 'wifi-sec.psk', old_psk)
    if previous:
        reconnect_later(previous)
    return {'ok': False, 'reason': reason, 'detail': err.splitlines()[-1][:120] if err else ''}


def wifi_forget(msg, _progress):
    ssid = str(msg.get('ssid') or '')
    ok = True
    for name, uuid in wifi_profiles().items():
        if name == ssid:
            ok = nmcli('connection', 'delete', 'uuid', uuid).returncode == 0 and ok
    return {'ok': ok}


UPDATE_STATE = '/var/lib/thinksmart-update'


def update_status(_msg, _progress):
    """What the root updater (thinksmart-update) found or is doing, for the welcome page."""
    try:
        with open(os.path.join(UPDATE_STATE, 'status.json')) as f:
            return {'ok': True, 'update': json.load(f)}
    except (OSError, ValueError):
        return {'ok': False}


def update_request(msg, _progress):
    """Ask the updater to install the versions the user tapped: the client's and/or the system
    layer's (it installs only what it checked itself)."""
    action = 'install' if msg.get('cmd') == 'update_install' else 'check'
    try:
        tmp = os.path.join(UPDATE_STATE, 'requests', f'.{action}.tmp')
        with open(tmp, 'w') as f:
            json.dump({'action': action, 'version': str(msg.get('version') or ''),
                       'system': str(msg.get('system') or '')}, f)
        os.replace(tmp, os.path.join(UPDATE_STATE, 'requests', action))
        return {'ok': True}
    except OSError:
        return {'ok': False}


def run_command(handler, msg, progress):
    """A page's command, always with an answer: a page waiting on one that never comes stays busy
    (the Wi-Fi panel can't be closed). nmcli hanging past its timeout, NetworkManager restarting,
    anything else: {ok: false} with a reason the pages know."""
    try:
        r = handler(msg, progress)
        return r if isinstance(r, dict) else {'ok': False, 'reason': 'failed'}
    except subprocess.TimeoutExpired:
        return {'ok': False, 'reason': 'timeout'}
    except Exception as e:  # noqa: BLE001 - the page still needs its answer
        print(f'thinksmart-kiosk: {msg.get("cmd")} failed: {e!r}', file=sys.stderr, flush=True)
        return {'ok': False, 'reason': 'failed', 'detail': str(e)[:120]}


LOOPBACK = ('127.0.0.1', 'localhost', '::1')
WIFI_COMMANDS = {'wifi_status': wifi_status, 'scan': wifi_scan, 'connect': wifi_connect, 'forget': wifi_forget}
WELCOME_COMMANDS = dict(WIFI_COMMANDS, update_status=update_status, update_install=update_request,
                        update_check=update_request)


def page_commands(uri, url):
    """What the page now on screen may ask for: the welcome page everything, the configured page
    only Wi-Fi and only when this device serves it (the voice client's settings), others nothing.
    A page on the network can't take over the device's Wi-Fi, nor can one the user navigates to."""
    if uri.startswith('file://' + WELCOME):
        return WELCOME_COMMANDS
    page, conf = urllib.parse.urlparse(uri), urllib.parse.urlparse(url or '')
    if (page.scheme in ('http', 'https') and (page.scheme, page.netloc) == (conf.scheme, conf.netloc)
            and page.hostname in LOOPBACK):
        return WIFI_COMMANDS
    return {}


def reachable(url):
    """True once something answers at url (any HTTP status counts, except gateway/upstream errors)."""
    if not url:
        return False
    if url.startswith('file://'):
        return os.path.exists(urllib.parse.urlparse(url).path)
    try:
        urllib.request.urlopen(url, timeout=2).close()
        return True
    except urllib.error.HTTPError as e:
        # Gateway or upstream server errors (e.g. reverse proxy starting up before the backend,
        # or backend restarting) mean the target application is not ready yet; stay on the
        # welcome page with retry instead of rendering an unhandled 502/503 error.
        if e.code in (502, 503, 504):
            return False
        return True
    except (OSError, ValueError):
        return False


def main():
    conf = read_conf()
    url = conf.get('URL', '')
    # Extra environment for the WebKit/Mesa renderer, e.g. WEBKIT_ENV="WEBKIT_FORCE_VBLANK_TIMER=1";
    # set before the web process is spawned so it inherits them
    for item in conf.get('WEBKIT_ENV', '').split():
        key, _, value = item.partition('=')
        if key:
            os.environ[key] = value

    data_dir = os.path.expanduser('~/.local/share/thinksmart-kiosk')
    cache_dir = os.path.expanduser('~/.cache/thinksmart-kiosk')
    manager = WebKit2.WebsiteDataManager(base_data_directory=data_dir,
                                         base_cache_directory=cache_dir)
    manager.get_cookie_manager().set_persistent_storage(
        os.path.join(data_dir, 'cookies.sqlite'), WebKit2.CookiePersistentStorage.SQLITE)
    context = WebKit2.WebContext.new_with_website_data_manager(manager)

    # A kiosk has nobody to click "play": allow media with sound to autoplay
    policies = WebKit2.WebsitePolicies(autoplay=WebKit2.AutoplayPolicy.ALLOW)
    # The welcome page talks to us through window.webkit.messageHandlers.thinksmart (Wi-Fi setup)
    ucm = WebKit2.UserContentManager()
    ucm.register_script_message_handler('thinksmart')
    # The system keyboard, on every page (top frame); thinksmartShell tells pages what we offer
    shell = 'window.thinksmartShell = {version: 2, keyboard: true, wifi: true};'
    try:
        with open(KEYBOARD) as f:
            shell += '\n' + f.read()
    except OSError:
        shell = shell.replace('keyboard: true', 'keyboard: false')
    ucm.add_script(WebKit2.UserScript.new(shell, WebKit2.UserContentInjectedFrames.TOP_FRAME,
                                          WebKit2.UserScriptInjectionTime.START, None, None))
    view = WebKit2.WebView(web_context=context, website_policies=policies, user_content_manager=ucm)
    settings = view.get_settings()
    # Developer tools only when profiling: WEBKIT_ENV="... WEBKIT_INSPECTOR_HTTP_SERVER=127.0.0.1:9222",
    # then open http://127.0.0.1:9222 through an ssh tunnel
    settings.set_enable_developer_extras(bool(os.environ.get('WEBKIT_INSPECTOR_HTTP_SERVER')))
    settings.set_enable_smooth_scrolling(True)
    settings.set_media_playback_requires_user_gesture(False)
    # GPU=never|on-demand|always in the conf. CPU rendering is the fallback default; GPU needs
    # the freedreno GMEM fix (mesa/ in this repository) or FD_MESA_DEBUG=sysmem, see README.
    policy = {
        'on-demand': WebKit2.HardwareAccelerationPolicy.ON_DEMAND,
        'always': WebKit2.HardwareAccelerationPolicy.ALWAYS,
    }.get(conf.get('GPU', 'never'), WebKit2.HardwareAccelerationPolicy.NEVER)
    settings.set_hardware_acceleration_policy(policy)
    # WEBKIT_FEATURES="-Name +Name": switch WebKit feature flags (names from
    # WebKit2.Settings.get_all_features()), e.g. to turn off partial-repaint damage tracking
    features = {}
    all_features = WebKit2.Settings.get_all_features()
    for i in range(all_features.get_length()):
        features[all_features.get(i).get_identifier()] = all_features.get(i)
    for item in conf.get('WEBKIT_FEATURES', '').split():
        name = item.lstrip('+-')
        if name in features:
            settings.set_feature_enabled(features[name], not item.startswith('-'))
        else:
            print(f'thinksmart-kiosk: unknown WebKit feature {name}', flush=True)

    # busy: the Wi-Fi sheet is open on the welcome page, don't switch pages under the user's fingers
    state = {'welcome': False, 'tries': 0, 'checking': False, 'busy': False}

    def run_js(fn, obj):
        view.evaluate_javascript('window.%s && %s(%s)' % (fn, fn, json.dumps(obj, ensure_ascii=False)),
                                 -1, None, None, None, None, None)

    def on_message(_ucm, result):
        uri = view.get_uri() or ''
        commands = page_commands(uri, url)
        try:
            msg = json.loads(result.get_js_value().to_string())
        except ValueError:
            return
        if not isinstance(msg, dict):
            return
        if msg.get('cmd') == 'busy' and commands is WELCOME_COMMANDS:
            state['busy'] = bool(msg.get('value'))
            run_js('thinksmartReply', {'id': msg.get('id'), 'ok': True})
            return
        handler = commands.get(msg.get('cmd'))
        if handler is None:
            if commands:
                run_js('thinksmartReply', {'id': msg.get('id'), 'ok': False, 'reason': 'unknown'})
            return

        def progress(stage):
            GLib.idle_add(run_js, 'thinksmartProgress', {'id': msg.get('id'), 'stage': stage})

        def work():
            r = run_command(handler, msg, progress)
            r['id'] = msg.get('id')
            # the address and Wi-Fi name may have just changed (not after the update polls: every 3 s)
            st = None if str(msg.get('cmd', '')).startswith('update_') else page_status()

            def done():
                if view.get_uri() != uri:  # the page changed meanwhile: the answer isn't for this one
                    return False
                run_js('thinksmartReply', r)
                if st and commands is WELCOME_COMMANDS:
                    run_js('thinksmartStatus', st)
                return False
            GLib.idle_add(done)
        threading.Thread(target=work, daemon=True).start()

    ucm.connect('script-message-received::thinksmart', on_message)

    def page_status():
        st = device_status()
        st.update(target=url, tries=state['tries'], help=conf.get('HELP_URL', ''))
        return st

    def show_welcome():
        state['welcome'] = True
        view.load_uri('file://' + WELCOME + '?' + urllib.parse.urlencode(page_status()))

    def on_load_failed(_view, _event, failing_uri, error):
        # Cancelled loads are our own navigations (e.g. switching to the welcome page)
        if (failing_uri.startswith('file://' + WELCOME) or
                error.matches(WebKit2.NetworkError.quark(), WebKit2.NetworkError.CANCELLED)):
            return False
        GLib.idle_add(show_welcome)
        return True  # no WebKit error page

    def check_target():
        """Every few seconds while the welcome page is up: retry the URL off the main thread."""
        if state['welcome'] and not state['checking']:
            state['checking'] = True

            def work():
                ok = reachable(url) and not needs_network_setup()
                st = None if ok else page_status()

                def done():
                    state['checking'] = False
                    if not state['welcome']:
                        return False
                    if ok and not state['busy']:
                        state['welcome'] = False
                        view.load_uri(url)
                    elif not ok:
                        state['tries'] += 1
                        st['tries'] = state['tries']
                        run_js('thinksmartStatus', st)
                    return False
                GLib.idle_add(done)
            threading.Thread(target=work, daemon=True).start()
        return True

    def reload():
        if url and not needs_network_setup():
            view.load_uri(url)
        else:
            show_welcome()
        return False

    def on_terminated(*_args):
        GLib.timeout_add_seconds(2, reload)

    view.connect('load-failed', on_load_failed)
    view.connect('web-process-terminated', on_terminated)
    view.connect('context-menu', lambda *_args: True)  # no long-press menu
    # No pinch zoom on any page: WebKitGTK zooms with its own two-finger gesture on the view,
    # whatever the page's viewport tag or touch-action say (both are iOS-only in WebKit). GDK
    # marks the first finger on the screen as emulating the pointer; touches that land while
    # it is down are dropped before WebKit and its gestures see them, so the zoom gesture never
    # gets a second finger. Taps, scrolling and dragging with one finger are unchanged.
    # (The field, not event.get_pointer_emulated(): that flag is lost in the copy Python gets.)
    view.connect('touch-event', lambda _view, event: not event.touch.emulating_pointer)
    GLib.timeout_add_seconds(RETRY_SECONDS, check_target)

    window = Gtk.Window(title='ThinkSmart Kiosk')
    window.add(view)
    window.connect('destroy', Gtk.main_quit)
    window.fullscreen()
    window.show_all()
    reload()
    Gtk.main()


if __name__ == '__main__':
    main()
