import pathlib,subprocess,time,json,datetime
R=pathlib.Path.cwd(); H=R/'.sf-lab/home'; E=pathlib.Path('~/.no-mistakes/evidence/01M6HDVCQG2SFKA0B68CD54WW4');S=(E/'session.txt').read_text().strip()
def log(x):
 s=datetime.datetime.now(datetime.timezone.utc).isoformat()+' '+x;print(s,flush=True)
 with (E/'boundary-actions.log').open('a') as f:f.write(s+'\n')
def hd(*a):return subprocess.check_output(['bin/fm-herdr-lab.sh','run',S,*a],text=True)
def epoch():return (H/'state/.claude-autoarm-epoch').read_text()
def save(tag):
 d={p.name:p.read_text() for p in (H/'state').glob('.*') if p.is_file() and p.stat().st_size<100000};(E/(tag+'-state.json')).write_text(json.dumps(d,indent=2));(E/(tag+'-screen.txt')).write_text(hd('pane','read','w1:p1','--source','visible'));log(tag+' '+epoch().splitlines()[0])
(H/'state/.afk').unlink();(H/'config/supervision-handoff-ack').unlink();(H/'state/.claude-autoarm-stopfailure-rewake').touch();log('AFK removed; acknowledged handback disabled; cooldown marker renewed')
hd('pane','send-text','w1:p1','say the single word anchor');hd('pane','send-keys','w1:p1','enter');log('submitted one primary prompt')
time.sleep(9);save('need-before-removal');assert 'outcome=arming' in epoch(),epoch();(H/'state/demo.meta').unlink();log('removed last task metadata during paced continuation')
time.sleep(24);save('need-after-removal');assert 'outcome=clean' in epoch(),epoch();log('PASS lost need ends silently')
