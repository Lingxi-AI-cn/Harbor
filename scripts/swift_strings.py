"""Small Swift string scanner for localization audits, including nested interpolation."""
from pathlib import Path
import re,json

def scan(s):
 out=[]
 def string(i):
  start=i;raw=0
  while s[i]=='#':raw+=1;i+=1
  if s[i]!='"':return start+1
  quote='"""' if s.startswith('"""',i) else '"';i+=len(quote);body=i;parts=[];expr=[];text=''
  close=quote+'#'*raw;esc='\\'+'#'*raw
  while i<len(s):
   if s.startswith(close,i):
    parts.append(text);end=i+len(close)
    key=''.join(p+('{'+str(n)+'}' if n<len(expr) else '') for n,p in enumerate(parts))
    out.append({'start':start,'end':end,'literal':s[start:end],'key':key,'expressions':expr});return end
   if s.startswith(esc+'(',i):
    parts.append(text);text='';i+=len(esc)+1;e=i;depth=1
    while i<len(s) and depth:
     if s[i]=='"' or (s[i]=='#' and re.match(r'#+"',s[i:])):i=string(i);continue
     if s[i]=='(':depth+=1
     elif s[i]==')':depth-=1
     i+=1
    expr.append(s[e:i-1]);continue
   if s.startswith(esc,i):
    j=i+len(esc);c=s[j]
    if c in {'n':'\n','r':'\r','t':'\t','0':'\0','"':'"','\\':'\\'}:text+= {'n':'\n','r':'\r','t':'\t','0':'\0','"':'"','\\':'\\'}[c];i=j+1;continue
    if c=='u' and s[j+1:j+2]=='{':
     k=s.index('}',j);text+=chr(int(s[j+2:k],16));i=k+1;continue
    text+=s[i:j+1];i=j+1;continue
   text+=s[i];i+=1
  raise ValueError('Unclosed string')
 i=0
 while i<len(s):
  if s.startswith('//',i):
   n=s.find('\n',i);i=n if n>=0 else len(s);continue
  if s.startswith('/*',i):
   d=1;i+=2
   while d and i<len(s):
    if s.startswith('/*',i):d+=1;i+=2
    elif s.startswith('*/',i):d-=1;i+=2
    else:i+=1
   continue
  if s[i]=='"' or (s[i]=='#' and re.match(r'#+"',s[i:])):i=string(i)
  else:i+=1
 return sorted(out,key=lambda v:v['start'])
