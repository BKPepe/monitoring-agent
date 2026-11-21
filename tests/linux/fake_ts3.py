"""A stand-in TeamSpeak 3 ServerQuery on 10011: greeting, then one virtual
server in the serverlist answer, then the error line that ends an exchange."""
import socket, threading
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 10011))
srv.listen(5)

def serve(c):
    c.sendall(b"TS3\n\rWelcome to the TeamSpeak 3 ServerQuery interface\n\r")
    data = b""
    try:
        while b"quit" not in data:
            chunk = c.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"serverlist" in data:
                c.sendall(b"virtualserver_id=1 virtualserver_port=9987 virtualserver_clientsonline=7 "
                          b"virtualserver_maxclients=32 virtualserver_name=Blood\\sKings\n\r"
                          b"error id=0 msg=ok\n\r")
                break
    finally:
        c.close()

while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
