import os
os.environ["OPENAI_API_KEY"] = "dummy"

from flask import Flask, request, jsonify
from routellm.routers.routers import ROUTER_CLS

app = Flask(__name__)
router = ROUTER_CLS["bert"](checkpoint_path="routellm/bert")

@app.route("/route", methods=["POST"])
def route():
    prompt = request.json.get("prompt", "")
    threshold = request.json.get("threshold", 0.5)
    score = float(router.calculate_strong_win_rate(prompt))
    return jsonify({"score": score, "route": "strong" if score > threshold else "weak"})

@app.route("/health")
def health():
    return "ok"

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=6060, threaded=True)
