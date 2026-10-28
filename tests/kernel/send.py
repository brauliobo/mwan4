import socket, os, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
n = 0
while not os.path.exists(sys.argv[1]):
    for _ in range(200):
        s.sendto(b'x', ('100.64.%d.%d' % ((n >> 8) & 255, n & 255), 9)); n += 1
print(n)
