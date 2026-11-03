exec(open('.sf-boundaries.py').read().split("(H/'state/.afk').unlink()")[0])
import os,signal
p=H/'state/.watch.lock/pid'
if p.exists():
 pid=int(p.read_text());os.kill(pid,signal.SIGTERM);log('terminated lab watcher '+str(pid));time.sleep(2)
(H/'config/supervision-host').write_text('off\n');(H/'state/demo.meta').write_text('project=demo\nwindow=unreachable-lab\nharness=claude\n');(H/'bin/fm-watch.sh').chmod(0o644)
log('fault injection: real watcher executable permission removed in disposable lab; host disabled to test shared failure continuation')
hd('pane','send-text','w1:p1','say the single word buoy');hd('pane','send-keys','w1:p1','enter');log('submitted one prompt; no more primary input')
time.sleep(13);save('failure-first');assert (H/'state/.claude-autoarm-failure-notified').exists()
time.sleep(23);save('failure-repeat');assert 'outcome=arming' in epoch() or 'outcome=failed-suppressed' in epoch(),epoch()
(H/'state/.afk').touch();log('AFK set during repeated failure continuation cooldown')
time.sleep(24);save('failure-afk');assert 'outcome=afk' in epoch(),epoch();log('PASS failure continuations paced; AFK suppressed terminal retry')
