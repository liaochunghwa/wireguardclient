import os
import re
import subprocess
import secrets
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, session, flash, send_file, jsonify
import io

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', secrets.token_hex(32))

WG_CONF_DIR = os.environ.get('WG_CONF_DIR', '/config/wg_confs')
WG_CONF_FILE = os.path.join(WG_CONF_DIR, 'wg0.conf')
WG_CLIENT_CONTAINER = os.environ.get('WG_CLIENT_CONTAINER', 'wireguard-client')
WG_LISTEN_PORT = os.environ.get('WG_LISTEN_PORT', '51821')
WG_VPN_SUBNET = os.environ.get('WG_VPN_SUBNET', '10.8.0.0/24')

os.makedirs(WG_CONF_DIR, exist_ok=True)

ADMIN_USER = os.environ.get('ADMIN_USER', 'admin')
ADMIN_PASS = os.environ.get('ADMIN_PASS', 'wireguard')

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

def read_wg_conf():
    try:
        with open(WG_CONF_FILE, 'r') as f:
            return f.read()
    except FileNotFoundError:
        return ''

def write_wg_conf(content):
    os.makedirs(WG_CONF_DIR, exist_ok=True)
    # Always end with a newline: without it, anything appended later (a hand
    # edited PersistentKeepalive, a shell `echo >>`) gets glued to the last
    # line and wg-quick fails with "Unrecognized service".
    with open(WG_CONF_FILE, 'w') as f:
        f.write(content.rstrip() + '\n')

def restart_wireguard_client():
    try:
        import docker
        client = docker.from_env()
        container = client.containers.get(WG_CLIENT_CONTAINER)
        container.restart(timeout=10)
        return True, 'WireGuard client 已重啟'
    except ImportError:
        r = subprocess.run(f'docker restart {WG_CLIENT_CONTAINER}', shell=True, capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            return True, 'WireGuard client 已重啟'
        return False, r.stderr
    except Exception as e:
        return False, str(e)

def validate_conf(content):
    """Return a list of error messages for an imported conf (empty = valid)."""
    errors = []
    pk = re.search(r'^PrivateKey\s*=\s*(\S+)', content, re.M)
    if not pk or not re.fullmatch(r'[0-9a-fA-F]{64}', pk.group(1)):
        errors.append('PrivateKey 無效：需 64 字 hex（請貼上 wg-easy 實際匯出的 .conf，不要用範本）')
    pub = re.search(r'^PublicKey\s*=\s*(\S+)', content, re.M)
    if not pub or not re.fullmatch(r'[0-9a-fA-F]{64}', pub.group(1)):
        errors.append('PublicKey 無效：需 64 字 hex')
    if not re.search(r'^Endpoint\s*=\s*\S+', content, re.M):
        errors.append('缺少 Endpoint（同 LAN 用 192.168.50.148:51820，外網用 DDNS 域名）')
    return errors

def normalize_conf(content, vpn_only=False):
    """Fix common wg-easy export issues so wg-quick can bring up wg0 reliably."""
    # wg-easy exports have no ListenPort -> random port drift after restarts
    if not re.search(r'^ListenPort\s*=', content, re.M):
        content = re.sub(
            r'^(PrivateKey\s*=\s*\S+)',
            lambda m: m.group(1) + f'\nListenPort = {WG_LISTEN_PORT}',
            content, count=1, flags=re.M)
    # wg-easy defaults to 0.0.0.0/0, ::/0 (all traffic through the tunnel),
    # which can break the host's LAN/internet if the server does not forward.
    if vpn_only:
        content = re.sub(r'^AllowedIPs\s*=.*$', f'AllowedIPs = {WG_VPN_SUBNET}',
                        content, flags=re.M)
    if not re.search(r'^PersistentKeepalive\s*=', content, re.M):
        content = re.sub(
            r'^(Endpoint\s*=\s*\S+)',
            lambda m: m.group(1) + '\nPersistentKeepalive = 25',
            content, count=1, flags=re.M)
    return content

def apply_wireguard():
    """Apply the new conf inside the client container (no full restart needed).
    The in-container wg-auto-up watcher also picks up changes within ~15s."""
    try:
        import docker
        client = docker.from_env()
        container = client.containers.get(WG_CLIENT_CONTAINER)
        r = container.exec_run(
            ['bash', '-c', 'wg-quick down wg0 2>/dev/null; wg-quick up wg0'])
        if r.exit_code == 0:
            return True, '設定已套用，wg0 已重新連線'
        return True, '設定已寫入，client 的 auto-up 服務將自動重試連線'
    except Exception:
        return True, '設定已寫入，client 的 auto-up 服務將自動套用（約 15 秒內）'

def run_cmd(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 'Command timed out'
    except Exception as e:
        return str(e)

def parse_wg_show(output):
    peers = []
    current = {}
    for line in output.strip().split('\n'):
        line = line.strip()
        if line.startswith('interface: wg0'):
            continue
        if line.startswith('peer:'):
            if current:
                peers.append(current)
            current = {'public_key': line.split(':', 1)[1].strip(), 'connected': False}
        elif 'endpoint:' in line:
            current['endpoint'] = line.split(':', 1)[1].strip()
        elif 'allowed ips:' in line:
            current['allowed_ips'] = line.split(':', 1)[1].strip()
        elif 'latest handshake:' in line:
            current['handshake'] = line.split(':', 1)[1].strip()
            current['connected'] = True
        elif 'transfer:' in line:
            m = re.search(r'received (\S+), sent (\S+)', line)
            if m:
                current['rx'] = m.group(1)
                current['tx'] = m.group(2)
    if current:
        peers.append(current)
    return peers

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('username') == ADMIN_USER and request.form.get('password') == ADMIN_PASS:
            session['logged_in'] = True
            return redirect(url_for('index'))
        flash('帳號或密碼錯誤', 'error')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def index():
    conf_content = read_wg_conf()
    wg_status = run_cmd('wg show wg0')
    peers = parse_wg_show(wg_status)
    iface_up = 'wg0' in run_cmd('ip link show wg0 2>/dev/null')
    return render_template('index.html', conf=conf_content, peers=peers, iface_up=iface_up, status=wg_status)

@app.route('/import', methods=['POST'])
@login_required
def import_conf():
    if 'conf_file' in request.files and request.files['conf_file'].filename:
        f = request.files['conf_file']
        content = f.read().decode('utf-8', errors='replace')
    elif request.form.get('conf_text', '').strip():
        content = request.form.get('conf_text').strip()
    else:
        flash('請選擇檔案或貼上設定內容', 'error')
        return redirect(url_for('index'))

    if '[Interface]' not in content:
        flash('無效的 WireGuard 設定：缺少 [Interface] 區段', 'error')
        return redirect(url_for('index'))

    errors = validate_conf(content)
    if errors:
        for e in errors:
            flash(e, 'error')
        return redirect(url_for('index'))

    vpn_only = request.form.get('vpn_only') == '1'
    content = normalize_conf(content, vpn_only=vpn_only)

    if os.path.exists(WG_CONF_FILE):
        backup = WG_CONF_FILE + '.bak'
        subprocess.run(f'cp {WG_CONF_FILE} {backup}', shell=True)

    write_wg_conf(content)

    ok, msg = apply_wireguard()
    if ok:
        flash(msg, 'success')
    else:
        flash(f'設定已匯入，但套用失敗：{msg}。請手動重啟 wireguard-client 容器', 'warning')
    return redirect(url_for('index'))

@app.route('/save', methods=['POST'])
@login_required
def save_conf():
    content = request.form.get('conf_content', '').strip()
    if not content:
        flash('設定內容不能為空', 'error')
        return redirect(url_for('index'))
    if '[Interface]' not in content:
        flash('無效的 WireGuard 設定：缺少 [Interface] 區段', 'error')
        return redirect(url_for('index'))
    errors = validate_conf(content)
    if errors:
        for e in errors:
            flash(e, 'error')
        return redirect(url_for('index'))
    if os.path.exists(WG_CONF_FILE):
        backup = WG_CONF_FILE + '.bak'
        subprocess.run(f'cp {WG_CONF_FILE} {backup}', shell=True)
    write_wg_conf(content)

    ok, msg = apply_wireguard()
    if ok:
        flash(msg, 'success')
    else:
        flash(f'設定已儲存，但套用失敗：{msg}。請手動重啟 wireguard-client 容器', 'warning')
    return redirect(url_for('index'))

@app.route('/restart', methods=['POST'])
@login_required
def restart():
    ok, msg = restart_wireguard_client()
    if ok:
        flash('WireGuard client 已重新啟動', 'success')
    else:
        flash(f'重啟失敗：{msg}', 'error')
    return redirect(url_for('index'))

@app.route('/stop', methods=['POST'])
@login_required
def stop():
    run_cmd('wg-quick down wg0')
    flash('WireGuard 已停止', 'success')
    return redirect(url_for('index'))

@app.route('/download')
@login_required
def download():
    if not os.path.exists(WG_CONF_FILE):
        flash('設定檔不存在', 'error')
        return redirect(url_for('index'))
    return send_file(WG_CONF_FILE, as_attachment=True, download_name='wg0.conf')

@app.route('/api/status')
@login_required
def api_status():
    wg_status = run_cmd('wg show wg0')
    peers = parse_wg_show(wg_status)
    iface_up = 'wg0' in run_cmd('ip link show wg0 2>/dev/null')
    return jsonify({'interface_up': iface_up, 'peers': peers, 'raw': wg_status})

if __name__ == '__main__':
    port = int(os.environ.get('WG_UI_PORT', 5080))
    app.run(host='0.0.0.0', port=port, debug=False)
