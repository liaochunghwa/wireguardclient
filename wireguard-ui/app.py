import os
import re
import subprocess
import secrets
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, session, flash, send_file, jsonify
from werkzeug.utils import secure_filename
import io

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', secrets.token_hex(32))

WG_CONF_DIR = os.environ.get('WG_CONF_DIR', '/config/wg_confs')
WG_CONF_FILE = os.path.join(WG_CONF_DIR, 'wg0.conf')
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
    with open(WG_CONF_FILE, 'w') as f:
        f.write(content)

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
    # Method 1: file upload
    if 'conf_file' in request.files and request.files['conf_file'].filename:
        f = request.files['conf_file']
        content = f.read().decode('utf-8', errors='replace')
    # Method 2: textarea paste
    elif request.form.get('conf_text', '').strip():
        content = request.form.get('conf_text').strip()
    else:
        flash('請選擇檔案或貼上設定內容', 'error')
        return redirect(url_for('index'))

    if '[Interface]' not in content:
        flash('無效的 WireGuard 設定：缺少 [Interface] 區段', 'error')
        return redirect(url_for('index'))

    # Backup current config
    if os.path.exists(WG_CONF_FILE):
        backup = WG_CONF_FILE + '.bak'
        subprocess.run(f'cp {WG_CONF_FILE} {backup}', shell=True)

    write_wg_conf(content)

    # Restart WireGuard
    run_cmd('wg-quick down wg0 2>/dev/null')
    result = run_cmd('wg-quick up wg0')

    flash('設定已匯入並重新啟動 WireGuard', 'success')
    return redirect(url_for('index'))

@app.route('/restart', methods=['POST'])
@login_required
def restart():
    run_cmd('wg-quick down wg0 2>/dev/null')
    result = run_cmd('wg-quick up wg0')
    flash(f'WireGuard 已重新啟動', 'success')
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
