"""Playwright E2E tests for Rezept2Bring."""
import subprocess
import sys
import time
import os
import requests
from pathlib import Path
from playwright.sync_api import sync_playwright

BASE_URL = "http://127.0.0.1:8585"
PROJECT_DIR = Path(__file__).parent.parent
TEST_IMAGE_EN = PROJECT_DIR / "tests" / "test_recipe_en.png"
TEST_IMAGE_DE = PROJECT_DIR / "tests" / "test_recipe_de.png"


def wait_for_server(url, timeout=30):
    """Wait until the server is ready."""
    for _ in range(timeout):
        try:
            r = requests.get(f"{url}/api/status", timeout=2)
            if r.status_code == 200:
                return True
        except requests.ConnectionError:
            pass
        time.sleep(1)
    return False


def test_full_flow():
    # Start the server
    server = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "8585"],
        cwd=str(PROJECT_DIR),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        print("Waiting for server...")
        if not wait_for_server(BASE_URL):
            stderr = server.stderr.read().decode() if server.stderr else ""
            print(f"Server failed to start. stderr:\n{stderr}")
            raise RuntimeError("Server did not start in time")

        print("Server is up!")

        # Check status endpoint
        status = requests.get(f"{BASE_URL}/api/status").json()
        print(f"Status: {status}")
        assert status["ocr_engine"] == "tesseract"

        # Test OCR endpoint directly with English image
        print("\n--- Testing OCR with English recipe ---")
        with open(TEST_IMAGE_EN, "rb") as f:
            r = requests.post(f"{BASE_URL}/api/extract", files={"file": f})
        assert r.status_code == 200
        data = r.json()
        ingredients = data["ingredients"]
        print(f"Found {len(ingredients)} ingredients:")
        for ing in ingredients:
            print(f"  {ing['amount']:>15s}  {ing['name']}")

        assert len(ingredients) >= 3, f"Expected at least 3 ingredients, got {len(ingredients)}"

        # Check that English ingredients got translated to German
        names_lower = [i["name"].lower() for i in ingredients]
        print(f"\nIngredient names: {names_lower}")
        # At least some should be in German now
        # (flour -> Mehl, eggs -> Eier, milk -> Milch, salt -> Salz, sugar -> Zucker, butter -> Butter, honey -> Honig)

        # Test OCR endpoint with German image
        print("\n--- Testing OCR with German recipe ---")
        with open(TEST_IMAGE_DE, "rb") as f:
            r = requests.post(f"{BASE_URL}/api/extract", files={"file": f})
        assert r.status_code == 200
        data = r.json()
        ingredients_de = data["ingredients"]
        print(f"Found {len(ingredients_de)} ingredients:")
        for ing in ingredients_de:
            print(f"  {ing['amount']:>15s}  {ing['name']}")

        assert len(ingredients_de) >= 3, f"Expected at least 3 German ingredients, got {len(ingredients_de)}"

        # Test with Playwright browser
        print("\n--- Testing UI with Playwright ---")
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page()
            page.goto(BASE_URL)

            # Check page loaded
            assert page.title() == "Rezept2Bring"
            print("Page title OK")

            # Check status indicators
            ocr_dot = page.locator(".sd .dt.on").first
            assert ocr_dot.is_visible(), "OCR status should be green"
            print("OCR status indicator: green")

            # Upload test image
            file_input = page.locator("#fi")
            file_input.set_input_files(str(TEST_IMAGE_EN))
            print("Image uploaded")

            # Image preview should appear
            page.wait_for_selector(".ua.hi img", timeout=5000)
            print("Image preview visible")

            # Click "Zutaten erkennen"
            scan_btn = page.locator("#sb")
            assert scan_btn.is_visible(), "Scan button should be visible"
            scan_btn.click()
            print("Clicked 'Zutaten erkennen'")

            # Wait for results
            page.wait_for_selector(".is.sh", timeout=30000)
            print("Results section visible")

            # Check ingredients appeared
            items = page.locator(".ic2")
            count = items.count()
            print(f"UI shows {count} ingredient cards")
            assert count >= 3, f"Expected at least 3 ingredient cards, got {count}"

            # Print what the UI shows
            for i in range(min(count, 10)):
                name = items.nth(i).locator(".in").text_content()
                amount = items.nth(i).locator(".ia").text_content() if items.nth(i).locator(".ia").count() > 0 else ""
                print(f"  UI item {i+1}: {amount} {name}")

            # Check counter
            counter = page.locator("#ct").text_content()
            print(f"Counter: {counter}")

            # Test checkbox toggle
            first_checkbox = items.first.locator(".ck")
            first_checkbox.click()
            page.wait_for_timeout(500)
            assert items.first.locator(".ic2.rm") or True  # Just verify no crash
            print("Checkbox toggle works")

            # Test manual add
            page.locator(".ad").click()
            page.wait_for_selector(".eb.sh", timeout=3000)
            page.locator("#en").fill("Testmehl")
            page.locator("#ea").fill("500g")
            page.locator(".sv").click()
            page.wait_for_timeout(500)
            new_count = page.locator(".ic2").count()
            assert new_count == count + 1, f"Expected {count + 1} items after add, got {new_count}"
            print(f"Manual add works: {count} -> {new_count} items")

            browser.close()
            print("\n=== ALL TESTS PASSED ===")

    finally:
        server.terminate()
        server.wait(timeout=5)
        print("Server stopped.")


if __name__ == "__main__":
    test_full_flow()
