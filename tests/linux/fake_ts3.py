"""A stand-in TeamSpeak 3 ServerQuery on 10011: greeting, then an answer per
command line, each ended by the error line that closes an exchange.

BK_FAKE_TS3_MODE picks what serverlist says:
  (unset)   one virtual server, online
  offline   that one plus a stopped one, which carries no client counts
  denied    no permission for serverlist; the agent then asks each port
            with "use port=N" and "serverinfo"
"""
import os, socket, threading, time
MODE = os.environ.get("BK_FAKE_TS3_MODE", "")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 10011))
srv.listen(5)

RUNNING = (b"virtualserver_id=1 virtualserver_port=9987 virtualserver_clientsonline=7 "
           b"virtualserver_maxclients=32 virtualserver_name=Blood\\sKings")
STOPPED = b"virtualserver_id=2 virtualserver_port=9988 virtualserver_status=offline virtualserver_name=Stopped"
OK = b"error id=0 msg=ok\n\r"

def answer(line, state):
    if line == "serverlist":
        if MODE == "denied":
            return b"error id=2568 msg=insufficient\\sclient\\spermissions\n\r"
        body = RUNNING + (b"|" + STOPPED if MODE == "offline" else b"")
        return body + b"\n\r" + OK
    if line.startswith("use port="):
        state["port"] = line.split("=", 1)[1]
        return OK if state["port"] == "9987" else b"error id=1024 msg=invalid\\sserverID\n\r"
    if line == "serverinfo":
        # A real server answers after a moment; the agent must not take the
        # "use" line's ok for the end of the whole exchange.
        time.sleep(0.3)
        if state.get("port") != "9987":
            return b"error id=1024 msg=invalid\\sserverID\n\r"
        return (b"virtualserver_clientsonline=7 virtualserver_maxclients=32 "
                b"virtualserver_name=Blood\\sKings virtualserver_port=9987\n\r" + OK)
    return b"error id=256 msg=command\\snot\\sfound\n\r"

def serve(c):
    c.sendall(b"TS3\n\rWelcome to the TeamSpeak 3 ServerQuery interface\n\r")
    data = b""
    state = {}
    try:
        while True:
            chunk = c.recv(4096)
            if not chunk:
                break
            data += chunk
            while b"\n" in data:
                raw, data = data.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                if line == "quit":
                    return
                c.sendall(answer(line, state))
    finally:
        c.close()

while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
