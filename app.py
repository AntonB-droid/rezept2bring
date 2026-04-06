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


def extract_ingredients(image_bytes: bytes) -> list[dict]:
    """Use Claude Haiku Vision to extract ingredients from a recipe image."""
    if not client:
        L.error("No Anthropic API key configured")
        return {"title": "", "ingredients": []}

    # Compress image to JPEG to speed up upload to Claude
    from PIL import Image
    from io import BytesIO
    try:
        img = Image.open(BytesIO(image_bytes))
        # Resize if too large (iPhone screenshots can be 3000+ px)
        w, h = img.size
        if w > 1200:
            ratio = 1200 / w
            img = img.resize((1200, int(h * ratio)), Image.LANCZOS)
        buf = BytesIO()
        img.convert("RGB").save(buf, format="JPEG", quality=75)
        image_bytes = buf.getvalue()
        L.info(f"Image compressed to {len(image_bytes)//1024}KB ({img.size[0]}x{img.size[1]})")
    except Exception as e:
        L.warning(f"Image compression failed, using original: {e}")

    b64 = base64.standard_b64encode(image_bytes).decode("utf-8")
    media_type = "image/jpeg"

    response = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=1024,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {"type": "base64", "media_type": media_type, "data": b64},
                },
                {
                    "type": "text",
                    "text": (
                        "Extrahiere alle Zutaten aus diesem Rezeptbild. "
                        "Übersetze ALLE Zutaten ins Deutsche, egal welche Sprache das Original hat. "
                        "Rechne ALLE amerikanischen/imperiale Maßeinheiten ins metrische System um: "
                        "cups→ml, tablespoons→EL, teaspoons→TL, oz/ounces→g, lbs/pounds→g, fahrenheit→celsius. "
                        "Beispiel: 1 cup→240ml, 1/4 cup→60ml, 1 oz→28g, 1 lb→450g. "
                        "WICHTIG: Fasse gleiche oder sehr ähnliche Zutaten zusammen und addiere deren Mengen. "
                        "Verwende kurze, einfache Zutatnamen die man auf einer Einkaufsliste erwarten würde "
                        "(z.B. 'Butter' statt 'ungesalzene Butter zum Einfetten'). "
                        "Ignoriere Zubereitungsschritte, Überschriften, Werbung und Garnierhinweise. "
                        "Antworte NUR mit einem JSON-Objekt, kein anderer Text. "
                        "Format: {\"title\": \"Rezeptname auf Deutsch\", \"ingredients\": [{\"name\": \"Zutatname\", \"amount\": \"Menge\"}]}\n"
                        "Beispiel: {\"title\": \"Pfannkuchen\", \"ingredients\": [{\"name\": \"Mehl\", \"amount\": \"200g\"}, {\"name\": \"Eier\", \"amount\": \"3\"}]}"
                    ),
                },
            ],
        }],
    )

    raw = response.content[0].text.strip()
    L.info(f"Claude response: {raw[:500]}")

    # Parse JSON from response (handle markdown code blocks)
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1].rsplit("```", 1)[0].strip()

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        import re as _re
        # Try to find JSON object or array
        match = _re.search(r"\{.*\}", raw, _re.DOTALL)
        if match:
            parsed = json.loads(match.group())
        else:
            match = _re.search(r"\[.*\]", raw, _re.DOTALL)
            if match:
                parsed = {"title": "", "ingredients": json.loads(match.group())}
            else:
                L.error(f"Could not parse JSON from Claude response: {raw}")
                return {"title": "", "ingredients": []}

    # Handle both old array format and new object format
    if isinstance(parsed, list):
        title = ""
        ingredients = parsed
    else:
        title = parsed.get("title", "")
        ingredients = parsed.get("ingredients", [])

    # Normalize
    results = []
    for item in ingredients:
        name = item.get("name", "").strip()
        amount = item.get("amount", "").strip()
        if name and len(name) >= 2:
            results.append({"name": name[0].upper() + name[1:], "amount": amount})

    return {"title": title, "ingredients": results}


# --- Bring! Wrapper ---

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
        result = await self.bring.load_lists()
        return result.lists

    async def find_list(self, name):
        for lst in await self.get_lists():
            if lst.name.lower() == name.lower():
                return lst.listUuid
        lists = await self.get_lists()
        if lists:
            return lists[0].listUuid
        raise Exception("Keine Liste gefunden")

    async def get_existing_items(self, list_uuid):
        """Get all items currently on the list."""
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
                # Item exists with an amount - combine them
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


# --- Recipe Database ---

DB_PATH = os.path.join(os.path.dirname(__file__), "recipes.db")


def init_db():
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


def save_recipe(title: str, source_url: str, ingredients: list[dict]) -> int:
    conn = sqlite3.connect(DB_PATH)
    cur = conn.execute(
        "INSERT INTO recipes (title, source_url, ingredients, created_at) VALUES (?, ?, ?, ?)",
        (title, source_url, json.dumps(ingredients, ensure_ascii=False), datetime.now().isoformat()),
    )
    recipe_id = cur.lastrowid
    conn.commit()
    conn.close()
    return recipe_id


def get_recipes() -> list[dict]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM recipes ORDER BY created_at DESC").fetchall()
    conn.close()
    return [
        {
            "id": r["id"],
            "title": r["title"],
            "source_url": r["source_url"],
            "ingredients": json.loads(r["ingredients"]),
            "created_at": r["created_at"],
        }
        for r in rows
    ]


def delete_recipe(recipe_id: int):
    conn = sqlite3.connect(DB_PATH)
    conn.execute("DELETE FROM recipes WHERE id = ?", (recipe_id,))
    conn.commit()
    conn.close()


init_db()


# --- App Setup ---

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
    result = extract_ingredients(await file.read())
    return result


@app.post("/api/scan")
async def api_scan(file: UploadFile = File(...)):
    """One-shot: extract ingredients from image and push to Bring! list."""
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
            "message": f"{len(ingredients)} Zutaten zu '{BL}' hinzugefügt",
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


@app.get("/api/status")
async def api_status():
    return {
        "bring_connected": bw is not None and bw.ok,
        "ocr_engine": "claude-haiku-vision",
    }


@app.get("/", response_class=HTMLResponse)
async def index():
    with open("static/index.html") as f:
        return f.read()
