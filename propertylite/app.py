import csv, os
from flask import Flask, jsonify, request
app = Flask(__name__)
DATA_PATH = os.environ.get("PROPERTY_DATA_PATH", "rets_property_sample.csv")

def load_properties():
    with open(DATA_PATH, newline="") as f:
        return list(csv.DictReader(f))

@app.route("/health")
def health():
    return jsonify(status="ok")

@app.route("/properties")
def list_properties():
    city = request.args.get("city")
    rows = load_properties()
    if city:
        rows = [r for r in rows if r.get("L_City", "").lower() == city.lower()]
    return jsonify(rows[:50])

@app.route("/properties/<listing_id>")
def get_property(listing_id):
    rows = load_properties()
    match = next((r for r in rows if r.get("L_ListingID") == listing_id), None)
    if not match:
        return jsonify(error="not found"), 404
    return jsonify(match)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)