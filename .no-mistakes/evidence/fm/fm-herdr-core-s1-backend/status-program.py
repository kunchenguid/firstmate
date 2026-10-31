import os, sys, time

def report(state):
    print('\x1b]7501;state='+state+':app=lab-status-probe\x1b\\', end='', flush=True)

report('idle')
print('STATUS-PROBE-READY', flush=True)
for line in sys.stdin:
    line = line.rstrip('\r\n')
    with open(sys.argv[1], 'a') as f:
        f.write(line+'\n')
    print('RECEIVED:'+line, flush=True)
    if line == 'block':
        report('blocked')
    else:
        report('working')
        time.sleep(2)
        report('idle')
