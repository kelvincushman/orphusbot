# Warms kev after a start: one pass per typical request size, so the first real
# System 1 ask isn't the slow first pass of a new shape.
import json, time, urllib.request

URL = "http://127.0.0.1:8009/v1/systemone"
for _ in range(120):  # wait for the server, up to 10 minutes
    try:
        urllib.request.urlopen("http://127.0.0.1:8009/v1/models", timeout=5)
        break
    except Exception:
        time.sleep(5)
bots = {f"bot{i}": "does one kind of job for the owner, described in a sentence or two" for i in range(12)}
yes = {"type": "noul", "instructions": "Is it worth doing now?"}
for words in (10, 40, 120, 300, 700):
    state = " ".join(["the owner asked for something to be done"] * (words // 8 + 1))
    for qs in ({"bot": {"type": "choice", "instructions": "Which bot?", "criteria": bots}},
               {"verdict": {"type": "choice", "instructions": "Pass or ask?", "criteria": {"pass": "harmless", "ask": "else"}}},
               {"bot": {"type": "choice", "instructions": "Which bot?", "criteria": bots}, "act_now": yes},
               {"worth": yes}):
        for _ in range(2):
            body = json.dumps({"state": state, "questions": qs}).encode()
            req = urllib.request.Request(URL, body, {"content-type": "application/json"})
            try:
                urllib.request.urlopen(req, timeout=300).read()
            except Exception as e:
                print("warm-up pass failed:", e)
print("kev warm")
