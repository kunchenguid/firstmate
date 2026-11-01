import sys,time

def report(state):
    sys.stdout.write('\x1b]7501;state='+state+':app=lab-reporter\x1b\\')
    sys.stdout.flush()
report(sys.argv[1])
for line in sys.stdin:
    print('RECEIVED:'+repr(line),flush=True)
    report('working')
    time.sleep(2)
    report('done')
