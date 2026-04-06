#!/bin/bash
set -e
D="${D:-/volume1/docker/rezept2bring}"
mkdir -p "$D/static" && cd "$D"
echo "=== Rezept2Bring Installer ==="
if [ ! -f .env ]; then
read -p "Bring! E-Mail: " em
read -s -p "Bring! Passwort: " pw; echo
read -p "Listenname [Einkaufsliste]: " ln
ln=${ln:-Einkaufsliste}
printf "BRING_EMAIL=%s\nBRING_PASSWORD=%s\nBRING_LIST_NAME=%s\n" "$em" "$pw" "$ln" > .env
echo "[OK] .env erstellt"
fi
cat > requirements.txt <<'E'
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
aiohttp==3.11.11
Pillow==11.1.0
pytesseract==0.3.13
bring-api>=4.1.0
E
cat > Dockerfile <<'E'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y –no-install-recommends tesseract-ocr tesseract-ocr-deu libglib2.0-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install –no-cache-dir -r requirements.txt
COPY app.py .
COPY static/ static/
EXPOSE 8585
CMD ["uvicorn", "app:app", "–host", "0.0.0.0", "–port", "8585"]
E
cat > docker-compose.yml <<'E'
version: "3.8"
services:
rezept2bring:
build: .
container_name: rezept2bring
restart: unless-stopped
ports:
- "8585:8585"
env_file:
- .env
E
cat > app.py <<'PYEOF'
import os,re,logging
from typing import Optional
from io import BytesIO
import aiohttp
from fastapi import FastAPI,UploadFile,File,Request,HTTPException
from fastapi.responses import HTMLResponse
from contextlib import asynccontextmanager
from PIL import Image,ImageEnhance
import pytesseract
from bring_api import Bring,BringItemOperation
BE=os.environ.get("BRING_EMAIL","")
BP=os.environ.get("BRING_PASSWORD","")
BL=os.environ.get("BRING_LIST_NAME","Einkaufsliste")
logging.basicConfig(level=logging.INFO)
L=logging.getLogger("r2b")
class BW:
def **init**(s,e,p):s.email,s.password,s.bring,s._s,s.ok=e,p,None,None,False
async def login(s):
s._s=aiohttp.ClientSession();s.bring=Bring(s._s,s.email,s.password)
await s.bring.login();s.ok=True;L.info("Bring! OK")
async def glists(s):return(await s.bring.load_lists()).get("lists",[])
async def flist(s,n):
for l in await s.glists():
if l["name"].lower()==n.lower():return l["listUuid"]
ls=await s.glists()
if ls:return ls[0]["listUuid"]
raise Exception("Keine Liste")
async def save(s,u,items):
bi=[{"itemId":i["name"],"spec":i.get("amount","")}for i in items]
if bi:await s.bring.batch_update_list(u,bi,BringItemOperation.ADD)
return[{"item":i["itemId"],"status":"ok"}for i in bi]
async def close(s):
if s._s:await s._s.close()
U=r"(?:g|kg|ml|l|cl|dl|EL|TL|Stk|Prise|Bund|Beutel|Dose|Dosen|Pkg|Becher|Scheiben|Zehen|Handvoll|Tassen|Pck)"
SK={"zubereitung","zutaten","portionen","personen","anleitung","tipp","schritt","minuten","stunden","rezept","kalorien","kcal","vorbereitung","garzeit","backzeit","kochzeit","arbeitszeit","gesamtzeit","ruhezeit","servings","preparation","instructions","directions","nutrition","calories","werbung","anzeige","foto","bild","quelle"}
ES={"zubereitung","anleitung","so geht","schritt 1","step 1","instructions","directions","den ofen","backofen","vorheizen"}
NR=[r"https?://",r"www.",r".com\b",r".de\b",r"@",r"\bbank\b",r"\bVR[\s-]",r"\bsparkasse\b",r"\bgmbh\b",r"\bverlag\b",r"\bmagazin\b",r"\bfoto\b",r"\bshutterstock\b",r"\bcookie\b",r"\bdatenschutz\b",r"\bimpressum\b",r"\bnewsletter\b",r"\bpinterest\b",r"\bfacebook\b",r"\binstagram\b",r"\btwitter\b",r"\btiktok\b",r"\byoutube\b",r"\btreaty\b",r"\bkitchen\b"]
def pimg(b):
img=Image.open(BytesIO(b))
if img.mode!="RGB":img=img.convert("RGB")
w,h=img.size
if w<1000:s=1500/w;img=img.resize((int(w*s),int(h*s)),Image.LANCZOS)
img=ImageEnhance.Contrast(img).enhance(1.5);img=ImageEnhance.Sharpness(img).enhance(2.0)
img=img.convert("L");img=ImageEnhance.Contrast(img).enhance(1.8);return img
def noi(l):return any(re.search(p,l.lower())for p in NR)
def pline(l):
l=l.strip()
if not l or len(l)<2:return None
a,n="",l
m=re.match(rf"^([\d/,.-]+\s*{U})\s+(.+)$",l,re.I)
if m:a,n=m.group(1).strip(),m.group(2).strip()
else:
m=re.match(r"^([\d/,.-]+)\s+(.+)$",l)
if m:a,n=m.group(1).strip(),m.group(2).strip()
else:
m=re.match(r"^(etwas|evtl.?|optional|ca.?)\s+(.+)$",l,re.I)
if m:a,n=m.group(1).strip(),m.group(2).strip()
n=re.sub(r"\s*(.*?)\s*"," ",n).strip(" ,;.-")
if len(n)<2 or re.match(r"^[\d\s.,]+$",n)or n.lower()in SK:return None
return{"name":n[0].upper()+n[1:],"amount":a}
def ocr(b):
img=pimg(b)
try:raw=pytesseract.image_to_string(img,config="–oem 3 –psm 6 -l deu+eng")
except:raw=pytesseract.image_to_string(img,config="–oem 3 –psm 6")
L.info(f"OCR({len(raw)}):\n{raw[:300]}")
res,seen,ins=[],set(),False
for line in raw.strip().split("\n"):
line=line.strip()
if not line or len(line)<2:continue
lo=line.lower()
if re.search(r"\bzutaten\b",lo)and len(line)<40:ins=True;continue
if any(e in lo for e in ES)and ins:break
if noi(line)or any(s in lo for s in SK)or len(line)>80:continue
if re.match(r"^[\d\s.,-:|]+$",line):continue
i=pline(line)
if i and i["name"].lower()not in seen:seen.add(i["name"].lower());res.append(i)
return res
bw=None
@asynccontextmanager
async def lifespan(a):
global bw
if BE and BP:
bw=BW(BE,BP)
try:await bw.login()
except Exception as e:L.error(f"Bring!:{e}");bw=None
yield
if bw:await bw.close()
app=FastAPI(title="Rezept2Bring",lifespan=lifespan)
@app.post("/api/extract")
async def extract(file:UploadFile=File(…)):return{"ingredients":ocr(await file.read())}
@app.post("/api/bring/push")
async def push(req:Request):
if not bw or not bw.ok:raise HTTPException(503,"Bring! nicht verbunden.")
body=await req.json();items=body.get("items",[]);ln=body.get("list_name",BL)
try:u=await bw.flist(ln);r=await bw.save(u,items);return{"success":True,"results":r,"list":ln}
except Exception as e:L.error(f"Bring!:{e}");raise HTTPException(500,str(e))
@app.get("/api/bring/lists")
async def lists():
if not bw or not bw.ok:raise HTTPException(503,"Bring!")
return{"lists":[{"name":l["name"],"uuid":l["listUuid"]}for l in await bw.glists()]}
@app.get("/api/status")
async def status():return{"bring_connected":bw is not None and bw.ok,"ocr_engine":"tesseract"}
@app.get("/",response_class=HTMLResponse)
async def idx():
with open("static/index.html")as f:return f.read()
PYEOF
cat > static/index.html <<'HTEOF'

<!DOCTYPE html><html lang="de"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><meta name="apple-mobile-web-app-capable" content="yes"><title>Rezept2Bring</title><link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet"><style>:root{--bg:#0c0c0e;--s:#18181b;--s2:#222225;--bd:#2e2e33;--t:#f0f0f2;--t2:#9ca3af;--a:#22c55e;--r:#ef4444;--rad:14px}*{margin:0;padding:0;box-sizing:border-box}body{font-family:'DM Sans',-apple-system,sans-serif;background:var(--bg);color:var(--t);min-height:100dvh;-webkit-font-smoothing:antialiased}.hd{padding:20px 20px 16px;border-bottom:1px solid var(--bd);background:var(--bg);position:sticky;top:0;z-index:100}.hd h1{font-size:22px;font-weight:700}.hd h1 em{color:var(--a);font-style:normal}.hd .sub{font-size:13px;color:var(--t2);margin-top:2px}.sr{display:flex;gap:12px;margin-top:10px}.sd{display:flex;align-items:center;gap:5px;font-size:11px;color:var(--t2)}.dt{width:7px;height:7px;border-radius:50%;background:var(--r)}.dt.on{background:var(--a)}.ua{margin:20px;border:2px dashed var(--bd);border-radius:var(--rad);padding:40px 20px;text-align:center;cursor:pointer;transition:all .2s;position:relative;overflow:hidden}.ua:hover{border-color:var(--a);background:rgba(34,197,94,.04)}.ua.hi{padding:0;border-style:solid;border-color:var(--bd)}.ua .ic{font-size:36px;margin-bottom:10px}.ua .lb{font-size:15px;font-weight:500}.ua .ht{font-size:12px;color:var(--t2);margin-top:4px}.ua img{width:100%;max-height:300px;object-fit:cover;display:block}.ua .cb{position:absolute;bottom:12px;right:12px;background:rgba(0,0,0,.7);backdrop-filter:blur(10px);color:#fff;border:none;padding:6px 14px;border-radius:8px;font-size:12px;cursor:pointer}#fi{display:none}.sb{margin:0 20px 20px;width:calc(100% - 40px);padding:14px;background:var(--a);color:#000;border:none;border-radius:var(--rad);font-size:16px;font-weight:600;font-family:inherit;cursor:pointer;display:none}.sb.sh{display:block}.sb:disabled{opacity:.5}.ld{display:none;text-align:center;padding:40px 20px}.ld.sh{display:block}.sp{width:36px;height:36px;border:3px solid var(--bd);border-top-color:var(--a);border-radius:50%;animation:sp .8s linear infinite;margin:0 auto 14px}@keyframes sp{to{transform:rotate(360deg)}}.ld p{font-size:14px;color:var(--t2)}.is{display:none;padding:0 20px 100px}.is.sh{display:block}.sh2{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}.sh2 h2{font-size:17px;font-weight:600}.ct{font-size:12px;color:var(--t2);background:var(--s2);padding:3px 10px;border-radius:20px}.ic2{background:var(--s);border:1px solid var(--bd);border-radius:12px;padding:14px 16px;margin-bottom:8px;display:flex;align-items:center;gap:12px}.ic2.rm{opacity:.3;text-decoration:line-through}.ck{width:22px;height:22px;border:2px solid var(--bd);border-radius:6px;flex-shrink:0;cursor:pointer;display:flex;align-items:center;justify-content:center;background:transparent}.ck.on{background:var(--a);border-color:var(--a)}.ck.on::after{content:'\2713';color:#000;font-size:13px;font-weight:700}.ii{flex:1;cursor:pointer}.in{font-size:15px;font-weight:500}.ia{font-size:12px;color:var(--t2);margin-top:1px}.ie{background:none;border:none;color:var(--t2);font-size:16px;cursor:pointer}.ab{display:none;position:fixed;bottom:0;left:0;right:0;padding:16px 20px;padding-bottom:max(16px,env(safe-area-inset-bottom));background:var(--bg);border-top:1px solid var(--bd);z-index:100}.ab.sh{display:block}.bb{width:100%;padding:14px;background:var(--a);color:#000;border:none;border-radius:12px;font-size:16px;font-weight:600;font-family:inherit;cursor:pointer}.bb:disabled{opacity:.5}.ad{width:100%;padding:12px;margin-top:4px;background:var(--s);border:1px dashed var(--bd);border-radius:12px;color:var(--t2);font-size:14px;font-family:inherit;cursor:pointer}.ad:hover{border-color:var(--a);color:var(--a)}.eb{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:200;align-items:center;justify-content:center}.eb.sh{display:flex}.em{background:var(--s);border-radius:16px;width:90%;max-width:400px;padding:24px}.em h3{font-size:16px;font-weight:600;margin-bottom:16px}.em input{width:100%;padding:12px;background:var(--s2);border:1px solid var(--bd);border-radius:10px;color:var(--t);font-size:15px;font-family:inherit;margin-bottom:10px;outline:none}.em input:focus{border-color:var(--a)}.ebs{display:flex;gap:8px;margin-top:6px}.ebs button{flex:1;padding:11px;border:none;border-radius:10px;font-size:14px;font-weight:600;font-family:inherit;cursor:pointer}.sv{background:var(--a);color:#000}.dl{background:var(--r);color:#fff}.cn{background:var(--s2);color:var(--t2)}.tt{position:fixed;top:20px;left:50%;transform:translateX(-50%) translateY(-100px);background:var(--s);border:1px solid var(--bd);color:var(--t);padding:12px 20px;border-radius:12px;font-size:14px;font-weight:500;z-index:300;transition:transform .3s;white-space:nowrap}.tt.sh{transform:translateX(-50%) translateY(0)}.tt.ok{border-color:var(--a)}.tt.er{border-color:var(--r)}</style></head><body><div class="hd"><h1>Rezept<em>2</em>Bring</h1><div class="sub">Screenshot → Zutaten → Einkaufsliste</div><div class="sr"><div class="sd"><div class="dt on"></div>OCR</div><div class="sd"><div class="dt" id="db"></div>Bring!</div></div></div><div class="ua" id="ua" onclick="document.getElementById('fi').click()"><div class="ic">📸</div><div class="lb">Rezept-Screenshot hochladen</div><div class="ht">Tippe oder ziehe ein Bild hierher</div></div><input type="file" id="fi" accept="image/*" capture="environment"><button class="sb" id="sb" onclick="sc()">🔍 Zutaten erkennen</button><div class="ld" id="ld"><div class="sp"></div><p>Analysiert…</p></div><div class="is" id="is"><div class="sh2"><h2>Erkannte Zutaten</h2><span class="ct" id="ct">0</span></div><div id="il"></div><button class="ad" onclick="aM()">+ Zutat manuell</button></div><div class="ab" id="ab"><button class="bb" id="bn" onclick="pu()">🛒 → Bring!</button></div><div class="eb" id="el" onclick="if(event.target===this)hE()"><div class="em"><h3 id="et">Bearbeiten</h3><input id="en" placeholder="Name"><input id="ea" placeholder="Menge"><div class="ebs"><button class="dl" onclick="dI()">🗑</button><button class="cn" onclick="hE()">×</button><button class="sv" onclick="sE()">OK</button></div></div></div><div class="tt" id="tt"></div><script>let I=[],F=null,eI=null,n=0;fetch('/api/status').then(r=>r.json()).then(d=>{document.getElementById('db').className='dt '+(d.bring_connected?'on':'')}).catch(()=>{});const U=document.getElementById('ua'),FI=document.getElementById('fi');FI.onchange=e=>{if(e.target.files.length)hF(e.target.files[0])};U.ondragover=e=>{e.preventDefault()};U.ondrop=e=>{e.preventDefault();if(e.dataTransfer.files.length)hF(e.dataTransfer.files[0])};function hF(f){F=f;const r=new FileReader();r.onload=e=>{U.innerHTML='<img src="'+e.target.result+'"><button class="cb" onclick="event.stopPropagation();FI.click()">Ändern</button>';U.classList.add('hi')};r.readAsDataURL(f);document.getElementById('sb').classList.add('sh');document.getElementById('is').classList.remove('sh');document.getElementById('ab').classList.remove('sh')}async function sc(){if(!F)return;const b=document.getElementById('sb');b.disabled=true;b.textContent='⏳…';document.getElementById('ld').classList.add('sh');document.getElementById('is').classList.remove('sh');document.getElementById('ab').classList.remove('sh');try{const fd=new FormData();fd.append('file',F);const r=await fetch('/api/extract',{method:'POST',body:fd});if(!r.ok)throw new Error(r.status);const d=await r.json();I=d.ingredients.map(i=>({...i,id:n++,c:true}));rn();T(I.length?I.length+' Zutaten':'Keine erkannt',I.length?'ok':'er')}catch(e){T('Fehler: '+e.message,'er')}finally{b.disabled=false;b.textContent='🔍 Zutaten erkennen';document.getElementById('ld').classList.remove('sh')}}function rn(){const c=I.filter(i=>i.c).length;document.getElementById('ct').textContent=c+'/'+I.length;document.getElementById('il').innerHTML=I.map(i=>'<div class="ic2 '+(i.c?'':'rm')+'"><div class="ck '+(i.c?'on':'')+'" onclick="tg('+i.id+')"></div><div class="ii" onclick="eG('+i.id+')"><div class="in">'+X(i.name)+'</div>'+(i.amount?'<div class="ia">'+X(i.amount)+'</div>':'')+'</div><button class="ie" onclick="eG('+i.id+')">✏️</button></div>').join('');document.getElementById('is').classList.add('sh');document.getElementById('ab').classList.add('sh')}function tg(id){const i=I.find(x=>x.id===id);if(i){i.c=!i.c;rn()}}function eG(id){const i=I.find(x=>x.id===id);if(!i)return;eI=id;document.getElementById('et').textContent='Bearbeiten';document.getElementById('en').value=i.name;document.getElementById('ea').value=i.amount||'';document.getElementById('el').classList.add('sh');document.getElementById('en').focus()}function aM(){eI=-1;document.getElementById('et').textContent='Hinzufügen';document.getElementById('en').value='';document.getElementById('ea').value='';document.getElementById('el').classList.add('sh');document.getElementById('en').focus()}function sE(){const a=document.getElementById('en').value.trim(),b=document.getElementById('ea').value.trim();if(!a)return;if(eI===-1)I.push({id:n++,name:a,amount:b,c:true});else{const i=I.find(x=>x.id===eI);if(i){i.name=a;i.amount=b}}hE();rn()}function dI(){if(eI>=0)I=I.filter(i=>i.id!==eI);hE();rn()}function hE(){document.getElementById('el').classList.remove('sh');eI=null}async function pu(){const items=I.filter(i=>i.c).map(i=>({name:i.name,amount:i.amount||''}));if(!items.length){T('Nichts ausgewählt','er');return}const b=document.getElementById('bn');b.disabled=true;b.textContent='⏳…';try{const r=await fetch('/api/bring/push',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({items})});if(!r.ok){const e=await r.json();throw new Error(e.detail||r.status)}T(items.length+' → Bring! ✓','ok')}catch(e){T('Fehler: '+e.message,'er')}finally{b.disabled=false;b.textContent='🛒 → Bring!'}}function T(m,t){const e=document.getElementById('tt');e.textContent=m;e.className='tt sh '+(t||'');setTimeout(()=>e.className='tt',3000)}function X(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}</script></body></html>

HTEOF
echo "[*] Baue Container…"
docker compose up -d –build
echo ""
echo "[OK] Rezept2Bring laeuft!"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "[OK] http://${IP:-NAS-IP}:8585"