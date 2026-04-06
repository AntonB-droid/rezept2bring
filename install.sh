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
  read -p "Anthropic API Key: " ak
  printf "BRING_EMAIL=%s\nBRING_PASSWORD=%s\nBRING_LIST_NAME=%s\nANTHROPIC_API_KEY=%s\n" "$em" "$pw" "$ln" "$ak" > .env
  echo "[OK] .env erstellt"
fi
cat > requirements.txt <<'E'
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
aiohttp==3.11.11
Pillow==11.1.0
anthropic>=0.40.0
bring-api>=1.0.0
python-dotenv>=1.0.0
E
cat > Dockerfile <<'E'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY static/ static/
EXPOSE 8585
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8585"]
E
cat > docker-compose.yml <<'E'
services:
  rezept2bring:
    build: .
    container_name: rezept2bring
    restart: unless-stopped
    ports:
      - "8585:8585"
    env_file:
      - .env
    volumes:
      - ./data:/app/data
E
cat > app.py <<'PYEOF'
import os
import base64
import json
import logging
import sqlite3
from datetime import datetime
from contextlib import asynccontextmanager

from dotenv import load_dotenv

load_dotenv()

import aiohttp
import anthropic
from fastapi import FastAPI, UploadFile, File, Request, HTTPException
from fastapi.responses import HTMLResponse
from PIL import Image
from io import BytesIO

try:
    from bring_api import Bring, BringItemOperation
except ImportError:
    Bring = None
    BringItemOperation = None

BE = os.environ.get("BRING_EMAIL", "")
BP = os.environ.get("BRING_PASSWORD", "")
BL = os.environ.get("BRING_LIST_NAME", "Einkaufsliste")
ANTHROPIC_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

logging.basicConfig(level=logging.INFO)
L = logging.getLogger("r2b")

client = anthropic.Anthropic(api_key=ANTHROPIC_KEY) if ANTHROPIC_KEY else None


def extract_ingredients(image_bytes):
    if not client:
        L.error("No Anthropic API key configured")
        return {"title": "", "ingredients": []}
    try:
        img = Image.open(BytesIO(image_bytes))
        w, h = img.size
        if w > 1200:
            ratio = 1200 / w
            img = img.resize((1200, int(h * ratio)), Image.LANCZOS)
        buf = BytesIO()
        img.convert("RGB").save(buf, format="JPEG", quality=75)
        image_bytes = buf.getvalue()
        L.info(f"Image compressed to {len(image_bytes)//1024}KB")
    except Exception as e:
        L.warning(f"Image compression failed: {e}")
    b64 = base64.standard_b64encode(image_bytes).decode("utf-8")
    response = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=1024,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64}},
                {"type": "text", "text": (
                    "Extrahiere alle Zutaten aus diesem Rezeptbild. "
                    "Uebersetze ALLE Zutaten ins Deutsche, egal welche Sprache das Original hat. "
                    "Rechne ALLE amerikanischen/imperiale Masseinheiten ins metrische System um: "
                    "cups->ml, tablespoons->EL, teaspoons->TL, oz/ounces->g, lbs/pounds->g. "
                    "Beispiel: 1 cup->240ml, 1/4 cup->60ml, 1 oz->28g, 1 lb->450g. "
                    "WICHTIG: Fasse gleiche oder sehr aehnliche Zutaten zusammen und addiere deren Mengen. "
                    "Verwende kurze, einfache Zutatnamen die man auf einer Einkaufsliste erwarten wuerde. "
                    "Ignoriere Zubereitungsschritte, Ueberschriften, Werbung und Garnierhinweise. "
                    "Antworte NUR mit einem JSON-Objekt, kein anderer Text. "
                    'Format: {"title": "Rezeptname auf Deutsch", "ingredients": [{"name": "Zutatname", "amount": "Menge"}]}'
                )},
            ],
        }],
    )
    raw = response.content[0].text.strip()
    L.info(f"Claude response: {raw[:500]}")
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        import re
        match = re.search(r"\{.*\}", raw, re.DOTALL)
        if match:
            parsed = json.loads(match.group())
        else:
            match = re.search(r"\[.*\]", raw, re.DOTALL)
            if match:
                parsed = {"title": "", "ingredients": json.loads(match.group())}
            else:
                L.error(f"Could not parse: {raw}")
                return {"title": "", "ingredients": []}
    if isinstance(parsed, list):
        title = ""
        ingredients = parsed
    else:
        title = parsed.get("title", "")
        ingredients = parsed.get("ingredients", [])
    results = []
    for item in ingredients:
        name = item.get("name", "").strip()
        amount = item.get("amount", "").strip()
        if name and len(name) >= 2:
            results.append({"name": name[0].upper() + name[1:], "amount": amount})
    return {"title": title, "ingredients": results}


class BringWrapper:
    def __init__(self, email, password):
        self.email = email
        self.password = password
        self.bring = None
        self._session = None
        self.ok = False

    async def login(self):
        self._session = aiohttp.ClientSession()
        self.bring = Bring(self._session, self.email, self.password)
        await self.bring.login()
        self.ok = True
        L.info("Bring! connected")

    async def get_lists(self):
        return (await self.bring.load_lists()).lists

    async def find_list(self, name):
        for lst in await self.get_lists():
            if lst.name.lower() == name.lower():
                return lst.listUuid
        lists = await self.get_lists()
        if lists:
            return lists[0].listUuid
        raise Exception("Keine Liste gefunden")

    async def get_existing_items(self, list_uuid):
        result = await self.bring.get_list(list_uuid)
        existing = {}
        for item in result.items.purchase:
            existing[item.itemId.lower()] = {
                "itemId": item.itemId,
                "spec": item.specification or "",
            }
        return existing

    async def save_items(self, list_uuid, items):
        existing = await self.get_existing_items(list_uuid)
        batch = []
        for i in items:
            name = i["name"]
            new_amount = i.get("amount", "")
            key = name.lower()
            if key in existing and existing[key]["spec"] and new_amount:
                old = existing[key]["spec"]
                combined = f"{old} + {new_amount}"
                batch.append({"itemId": existing[key]["itemId"], "spec": combined})
            else:
                batch.append({"itemId": name, "spec": new_amount})
        if batch:
            await self.bring.batch_update_list(list_uuid, batch, BringItemOperation.ADD)
        return [{"item": i["itemId"], "status": "ok"} for i in batch]

    async def close(self):
        if self._session:
            await self._session.close()


DB_PATH = os.path.join(os.environ.get("DATA_DIR", "/app/data"), "recipes.db")


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""CREATE TABLE IF NOT EXISTS recipes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        source_url TEXT,
        ingredients TEXT,
        created_at TEXT
    )""")
    conn.commit()
    conn.close()


def save_recipe(title, source_url, ingredients):
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute(
        "INSERT INTO recipes (title, source_url, ingredients, created_at) VALUES (?, ?, ?, ?)",
        (title, source_url, json.dumps(ingredients, ensure_ascii=False), datetime.now().isoformat()),
    )
    recipe_id = cur.lastrowid
    conn.commit()
    conn.close()
    return recipe_id


def get_recipes():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM recipes ORDER BY created_at DESC").fetchall()
    conn.close()
    return [{"id": r["id"], "title": r["title"], "source_url": r["source_url"],
             "ingredients": json.loads(r["ingredients"]), "created_at": r["created_at"]} for r in rows]


def delete_recipe(recipe_id):
    conn = sqlite3.connect(DB_PATH)
    conn.execute("DELETE FROM recipes WHERE id = ?", (recipe_id,))
    conn.commit()
    conn.close()


init_db()

bw = None


@asynccontextmanager
async def lifespan(app):
    global bw
    if BE and BP and Bring:
        bw = BringWrapper(BE, BP)
        try:
            await bw.login()
        except Exception as e:
            L.error(f"Bring! connection failed: {e}")
            bw = None
    yield
    if bw:
        await bw.close()


app = FastAPI(title="Rezept2Bring", lifespan=lifespan)


@app.post("/api/extract")
async def api_extract(file: UploadFile = File(...)):
    return extract_ingredients(await file.read())


@app.post("/api/scan")
async def api_scan(file: UploadFile = File(...)):
    result = extract_ingredients(await file.read())
    title = result.get("title", "")
    ingredients = result.get("ingredients", [])
    if not ingredients:
        return {"success": False, "message": "Keine Zutaten erkannt", "title": title, "ingredients": []}
    if not bw or not bw.ok:
        return {"success": False, "message": "Bring! nicht verbunden", "title": title, "ingredients": ingredients}
    try:
        uuid = await bw.find_list(BL)
        await bw.save_items(uuid, ingredients)
        names = [f"{i['amount']} {i['name']}".strip() for i in ingredients]
        return {
            "success": True,
            "message": f"{len(ingredients)} Zutaten zu '{BL}' hinzugefuegt",
            "title": title,
            "ingredients": ingredients,
            "summary": "\n".join(names),
        }
    except Exception as e:
        L.error(f"Scan+push error: {e}")
        return {"success": False, "message": str(e), "title": title, "ingredients": ingredients}


@app.post("/api/bring/push")
async def api_push(req: Request):
    if not bw or not bw.ok:
        raise HTTPException(503, "Bring! nicht verbunden.")
    body = await req.json()
    items = body.get("items", [])
    list_name = body.get("list_name", BL)
    try:
        uuid = await bw.find_list(list_name)
        results = await bw.save_items(uuid, items)
        return {"success": True, "results": results, "list": list_name}
    except Exception as e:
        L.error(f"Bring! error: {e}")
        raise HTTPException(500, str(e))


@app.get("/api/bring/lists")
async def api_lists():
    if not bw or not bw.ok:
        raise HTTPException(503, "Bring! nicht verbunden.")
    return {"lists": [{"name": l.name, "uuid": l.listUuid} for l in await bw.get_lists()]}


@app.get("/api/recipes")
async def api_recipes():
    return {"recipes": get_recipes()}


@app.delete("/api/recipes/{recipe_id}")
async def api_delete_recipe(recipe_id: int):
    delete_recipe(recipe_id)
    return {"success": True}


@app.get("/api/status")
async def api_status():
    return {"bring_connected": bw is not None and bw.ok, "ocr_engine": "claude-haiku-vision"}


@app.get("/", response_class=HTMLResponse)
async def index():
    with open("static/index.html") as f:
        return f.read()
PYEOF
cat > static/index.html <<'HTEOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Rezept2Bring</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root{--bg:#0c0c0e;--s:#18181b;--s2:#222225;--bd:#2e2e33;--t:#f0f0f2;--t2:#9ca3af;--a:#22c55e;--r:#ef4444;--rad:14px}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'DM Sans',-apple-system,sans-serif;background:var(--bg);color:var(--t);min-height:100dvh;-webkit-font-smoothing:antialiased}
.hd{padding:20px 20px 16px;border-bottom:1px solid var(--bd);background:var(--bg);position:sticky;top:0;z-index:100}
.hd h1{font-size:22px;font-weight:700}.hd h1 em{color:var(--a);font-style:normal}
.hd .sub{font-size:13px;color:var(--t2);margin-top:2px}
.sr{display:flex;gap:12px;margin-top:10px}
.sd{display:flex;align-items:center;gap:5px;font-size:11px;color:var(--t2)}
.dt{width:7px;height:7px;border-radius:50%;background:var(--r)}.dt.on{background:var(--a)}
.ua{margin:20px;border:2px dashed var(--bd);border-radius:var(--rad);padding:40px 20px;text-align:center;cursor:pointer;transition:all .2s;position:relative;overflow:hidden}
.ua:hover{border-color:var(--a);background:rgba(34,197,94,.04)}
.ua.hi{padding:0;border-style:solid;border-color:var(--bd)}
.ua .ic{font-size:36px;margin-bottom:10px}.ua .lb{font-size:15px;font-weight:500}
.ua .ht{font-size:12px;color:var(--t2);margin-top:4px}
.ua img{width:100%;max-height:300px;object-fit:cover;display:block}
.ua .cb{position:absolute;bottom:12px;right:12px;background:rgba(0,0,0,.7);backdrop-filter:blur(10px);color:#fff;border:none;padding:6px 14px;border-radius:8px;font-size:12px;cursor:pointer}
#fi{display:none}
.sb{margin:0 20px 20px;width:calc(100% - 40px);padding:14px;background:var(--a);color:#000;border:none;border-radius:var(--rad);font-size:16px;font-weight:600;font-family:inherit;cursor:pointer;display:none}
.sb.sh{display:block}.sb:disabled{opacity:.5}
.ld{display:none;text-align:center;padding:40px 20px}.ld.sh{display:block}
.sp{width:36px;height:36px;border:3px solid var(--bd);border-top-color:var(--a);border-radius:50%;animation:sp .8s linear infinite;margin:0 auto 14px}
@keyframes sp{to{transform:rotate(360deg)}}
.ld p{font-size:14px;color:var(--t2)}
.is{display:none;padding:0 20px 100px}.is.sh{display:block}
.sh2{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}
.sh2 h2{font-size:17px;font-weight:600}
.ct{font-size:12px;color:var(--t2);background:var(--s2);padding:3px 10px;border-radius:20px}
.ic2{background:var(--s);border:1px solid var(--bd);border-radius:12px;padding:14px 16px;margin-bottom:8px;display:flex;align-items:center;gap:12px}
.ic2.rm{opacity:.3;text-decoration:line-through}
.ck{width:22px;height:22px;border:2px solid var(--bd);border-radius:6px;flex-shrink:0;cursor:pointer;display:flex;align-items:center;justify-content:center;background:transparent}
.ck.on{background:var(--a);border-color:var(--a)}.ck.on::after{content:'\2713';color:#000;font-size:13px;font-weight:700}
.ii{flex:1;cursor:pointer}.in{font-size:15px;font-weight:500}
.ia{font-size:12px;color:var(--t2);margin-top:1px}
.ie{background:none;border:none;color:var(--t2);font-size:16px;cursor:pointer}
.ab{display:none;position:fixed;bottom:0;left:0;right:0;padding:16px 20px;padding-bottom:max(16px,env(safe-area-inset-bottom));background:var(--bg);border-top:1px solid var(--bd);z-index:100}
.ab.sh{display:block}
.bb{width:100%;padding:14px;background:var(--a);color:#000;border:none;border-radius:12px;font-size:16px;font-weight:600;font-family:inherit;cursor:pointer}
.bb:disabled{opacity:.5}
.ad{width:100%;padding:12px;margin-top:4px;background:var(--s);border:1px dashed var(--bd);border-radius:12px;color:var(--t2);font-size:14px;font-family:inherit;cursor:pointer}
.ad:hover{border-color:var(--a);color:var(--a)}
.eb{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:200;align-items:center;justify-content:center}
.eb.sh{display:flex}
.em{background:var(--s);border-radius:16px;width:90%;max-width:400px;padding:24px}
.em h3{font-size:16px;font-weight:600;margin-bottom:16px}
.em input{width:100%;padding:12px;background:var(--s2);border:1px solid var(--bd);border-radius:10px;color:var(--t);font-size:15px;font-family:inherit;margin-bottom:10px;outline:none}
.em input:focus{border-color:var(--a)}
.ebs{display:flex;gap:8px;margin-top:6px}
.ebs button{flex:1;padding:11px;border:none;border-radius:10px;font-size:14px;font-weight:600;font-family:inherit;cursor:pointer}
.sv{background:var(--a);color:#000}.dl{background:var(--r);color:#fff}.cn{background:var(--s2);color:var(--t2)}
.tt{position:fixed;top:20px;left:50%;transform:translateX(-50%) translateY(-100px);background:var(--s);border:1px solid var(--bd);color:var(--t);padding:12px 20px;border-radius:12px;font-size:14px;font-weight:500;z-index:300;transition:transform .3s;white-space:nowrap}
.tt.sh{transform:translateX(-50%) translateY(0)}.tt.ok{border-color:var(--a)}.tt.er{border-color:var(--r)}
</style>
</head>
<body>
<div class="hd">
  <h1>Rezept<em>2</em>Bring</h1>
  <div class="sub">Screenshot &rarr; Zutaten &rarr; Einkaufsliste</div>
  <div class="sr">
    <div class="sd"><div class="dt on"></div>OCR</div>
    <div class="sd"><div class="dt" id="db"></div>Bring!</div>
  </div>
</div>
<div class="ua" id="ua" onclick="document.getElementById('fi').click()">
  <div class="ic">&#x1F4F8;</div>
  <div class="lb">Rezept-Screenshot hochladen</div>
  <div class="ht">Tippe oder ziehe ein Bild hierher</div>
</div>
<input type="file" id="fi" accept="image/*" capture="environment">
<button class="sb" id="sb" onclick="sc()">&#x1F50D; Zutaten erkennen</button>
<div class="ld" id="ld"><div class="sp"></div><p>Analysiert...</p></div>
<div class="is" id="is">
  <div class="sh2"><h2>Erkannte Zutaten</h2><span class="ct" id="ct">0</span></div>
  <div id="il"></div>
  <button class="ad" onclick="aM()">+ Zutat manuell</button>
</div>
<div class="ab" id="ab">
  <button class="bb" id="bn" onclick="pu()">&#x1F6D2; &rarr; Bring!</button>
</div>
<div class="eb" id="el" onclick="if(event.target===this)hE()">
  <div class="em">
    <h3 id="et">Bearbeiten</h3>
    <input id="en" placeholder="Name">
    <input id="ea" placeholder="Menge">
    <div class="ebs">
      <button class="dl" onclick="dI()">&#x1F5D1;</button>
      <button class="cn" onclick="hE()">&times;</button>
      <button class="sv" onclick="sE()">OK</button>
    </div>
  </div>
</div>
<div class="tt" id="tt"></div>
<script>
let I=[],F=null,eI=null,n=0;
fetch('/api/status').then(r=>r.json()).then(d=>{
  document.getElementById('db').className='dt '+(d.bring_connected?'on':'');
}).catch(()=>{});
const U=document.getElementById('ua'),FI=document.getElementById('fi');
FI.onchange=e=>{if(e.target.files.length)hF(e.target.files[0])};
U.ondragover=e=>{e.preventDefault()};
U.ondrop=e=>{e.preventDefault();if(e.dataTransfer.files.length)hF(e.dataTransfer.files[0])};
function hF(f){F=f;const r=new FileReader();r.onload=e=>{U.innerHTML='<img src="'+e.target.result+'"><button class="cb" onclick="event.stopPropagation();FI.click()">Aendern</button>';U.classList.add('hi')};r.readAsDataURL(f);document.getElementById('sb').classList.add('sh');document.getElementById('is').classList.remove('sh');document.getElementById('ab').classList.remove('sh')}
async function sc(){if(!F)return;const b=document.getElementById('sb');b.disabled=true;b.textContent='\u23F3...';document.getElementById('ld').classList.add('sh');document.getElementById('is').classList.remove('sh');document.getElementById('ab').classList.remove('sh');try{const fd=new FormData();fd.append('file',F);const r=await fetch('/api/extract',{method:'POST',body:fd});if(!r.ok)throw new Error(r.status);const d=await r.json();I=(d.ingredients||[]).map(i=>({...i,id:n++,c:true}));rn();T(I.length?I.length+' Zutaten erkannt':'Keine erkannt',I.length?'ok':'er')}catch(e){T('Fehler: '+e.message,'er')}finally{b.disabled=false;b.textContent='\uD83D\uDD0D Zutaten erkennen';document.getElementById('ld').classList.remove('sh')}}
function rn(){const c=I.filter(i=>i.c).length;document.getElementById('ct').textContent=c+'/'+I.length;document.getElementById('il').innerHTML=I.map(i=>'<div class="ic2 '+(i.c?'':'rm')+'"><div class="ck '+(i.c?'on':'')+'" onclick="tg('+i.id+')"></div><div class="ii" onclick="eG('+i.id+')"><div class="in">'+X(i.name)+'</div>'+(i.amount?'<div class="ia">'+X(i.amount)+'</div>':'')+'</div><button class="ie" onclick="eG('+i.id+')">&#x270F;&#xFE0F;</button></div>').join('');document.getElementById('is').classList.add('sh');document.getElementById('ab').classList.add('sh')}
function tg(id){const i=I.find(x=>x.id===id);if(i){i.c=!i.c;rn()}}
function eG(id){const i=I.find(x=>x.id===id);if(!i)return;eI=id;document.getElementById('et').textContent='Bearbeiten';document.getElementById('en').value=i.name;document.getElementById('ea').value=i.amount||'';document.getElementById('el').classList.add('sh');document.getElementById('en').focus()}
function aM(){eI=-1;document.getElementById('et').textContent='Hinzufuegen';document.getElementById('en').value='';document.getElementById('ea').value='';document.getElementById('el').classList.add('sh');document.getElementById('en').focus()}
function sE(){const a=document.getElementById('en').value.trim(),b=document.getElementById('ea').value.trim();if(!a)return;if(eI===-1)I.push({id:n++,name:a,amount:b,c:true});else{const i=I.find(x=>x.id===eI);if(i){i.name=a;i.amount=b}}hE();rn()}
function dI(){if(eI>=0)I=I.filter(i=>i.id!==eI);hE();rn()}
function hE(){document.getElementById('el').classList.remove('sh');eI=null}
async function pu(){const items=I.filter(i=>i.c).map(i=>({name:i.name,amount:i.amount||''}));if(!items.length){T('Nichts ausgewaehlt','er');return}const b=document.getElementById('bn');b.disabled=true;b.textContent='\u23F3...';try{const r=await fetch('/api/bring/push',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({items})});if(!r.ok){const e=await r.json();throw new Error(e.detail||r.status)}T(items.length+' \u2192 Bring! \u2713','ok')}catch(e){T('Fehler: '+e.message,'er')}finally{b.disabled=false;b.textContent='\uD83D\uDED2 \u2192 Bring!'}}
function T(m,t){const e=document.getElementById('tt');e.textContent=m;e.className='tt sh '+(t||'');setTimeout(()=>e.className='tt',3000)}
function X(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML}
</script>
</body>
</html>
HTEOF
echo "[*] Baue Container..."
docker compose up -d --build
echo ""
echo "[OK] Rezept2Bring laeuft!"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "[OK] http://${IP:-NAS-IP}:8585"
