"""Create a test image with recipe ingredients for OCR testing."""
from PIL import Image, ImageDraw, ImageFont

img = Image.new("RGB", (800, 600), "white")
draw = ImageDraw.Draw(img)

try:
    font = ImageFont.truetype("arial.ttf", 28)
    font_title = ImageFont.truetype("arial.ttf", 36)
except OSError:
    font = ImageFont.load_default()
    font_title = font

# English recipe
lines = [
    ("Ingredients", 40, font_title),
    ("2 cups all-purpose flour", 100, font),
    ("1 teaspoon baking powder", 140, font),
    ("3 eggs", 180, font),
    ("200ml whole milk", 220, font),
    ("100g butter", 260, font),
    ("1 pinch salt", 300, font),
    ("2 tablespoons sugar", 340, font),
    ("1/4 cup vegetable oil", 380, font),
    ("3 tablespoons honey", 420, font),
    ("fresh basil leaves", 460, font),
]

for text, y, f in lines:
    draw.text((40, y), text, fill="black", font=f)

img.save("tests/test_recipe_en.png")
print("Created tests/test_recipe_en.png")

# German recipe
img2 = Image.new("RGB", (800, 500), "white")
draw2 = ImageDraw.Draw(img2)

lines_de = [
    ("Zutaten", 40, font_title),
    ("250g Mehl", 100, font),
    ("3 Eier", 140, font),
    ("200ml Milch", 180, font),
    ("1 Prise Salz", 220, font),
    ("50g Zucker", 260, font),
    ("100g Butter", 300, font),
    ("1 Beutel Vanillezucker", 340, font),
]

for text, y, f in lines_de:
    draw2.text((40, y), text, fill="black", font=f)

img2.save("tests/test_recipe_de.png")
print("Created tests/test_recipe_de.png")
