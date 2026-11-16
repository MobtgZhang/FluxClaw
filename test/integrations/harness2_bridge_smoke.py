import subprocess,json,tempfile,pathlib,re,os,shutil
root=pathlib.Path(tempfile.mkdtemp(prefix='fluxclaw-text-bridge-'))
python=os.environ.get('FLUXCLAW_PYTHON',shutil.which('python3'))
p=subprocess.Popen([python,'-I','priv/integrations/harness2_runner.py'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
p.stdin.write(json.dumps({'operation':'optimize','task':'Write a two-step checklist for reviewing a document.','mode':'parallel','k':1,'output':str(root/'run'),'library':str(root/'library')})+'\n');p.stdin.flush()
calls=0
for line in p.stdout:
 d=json.loads(line)
 if d['type']=='llm':
  calls+=1
  if 'Return only JSON' in d['system']: answer=json.dumps({'systemprompt':'Write an accurate, concise two-step checklist.','notes':'Make the instructions concrete.'})
  elif '```choice' in d['user']:
   ids=re.findall(r'## candidates/([A-Z]+)\.md',d['user']);answer='<why>Meets the task.</why>\n```choice\n'+(ids[0] if ids else 'A')+'\n```'
  elif '<experience>' in d['user'] or '<edits>' in d['user']:answer='<edits>No observed difference.</edits>\nNO_ENTRY'
  else: answer='1. Check facts and evidence.\n2. Check structure and clarity.'
  p.stdin.write(json.dumps({'content':answer})+'\n');p.stdin.flush()
 else: print(json.dumps(d)); assert d['type']=='result', d
p.wait(timeout=30)
print('exit',p.returncode,'model calls',calls,'root',root)
print(p.stderr.read()[-2000:])
assert p.returncode==0
shutil.rmtree(root)
