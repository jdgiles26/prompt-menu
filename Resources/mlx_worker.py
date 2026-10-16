# Keeps an MLX model loaded for Prompt Menu between rewrites. Started by the app (WarmRunner.swift)
# with the Python that has mlx-lm installed; never run by hand.
#
# Talks only over stdin and stdout, one JSON object per line:
#   in:  {"id", "model", "system", "prompt", "max_tokens", "temp"}   or   {"cancel": id}
#   out: {"id", "text": "more text"} ... {"id", "done": true}   or   {"id", "error": "message"}
# Exits when stdin closes, which happens when the app quits or unloads the model.
# No network: models must already be downloaded (HF_HUB_OFFLINE).
import json
import os
import queue
import sys
import threading

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

from mlx_lm import load, stream_generate  # noqa: E402
from mlx_lm.sample_utils import make_sampler  # noqa: E402

requests = queue.Queue()
cancelled = set()
closed = threading.Event()
out_lock = threading.Lock()


def send(message):
    with out_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def read_input():
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if "cancel" in message:
            cancelled.add(message["cancel"])
        else:
            requests.put(message)
    closed.set()
    requests.put(None)


def chat_prompt(tokenizer, system, prompt):
    messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
    try:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    except Exception:
        # Some chat templates have no system role: put the instructions in the user's turn.
        merged = [{"role": "user", "content": system + "\n\n" + prompt}]
        return tokenizer.apply_chat_template(merged, add_generation_prompt=True)


def main():
    threading.Thread(target=read_input, daemon=True).start()
    loaded_name, model, tokenizer = None, None, None
    while True:
        request = requests.get()
        if request is None:
            return
        rid = request.get("id")
        try:
            if request["model"] != loaded_name:
                model, tokenizer, loaded_name = None, None, None  # free the old one first
                model, tokenizer = load(request["model"])
                loaded_name = request["model"]
            prompt = chat_prompt(tokenizer, request["system"], request["prompt"])
            sampler = make_sampler(temp=float(request.get("temp", 0.3)))
            for response in stream_generate(model, tokenizer, prompt, max_tokens=int(request.get("max_tokens", 1024)),
                                            sampler=sampler):
                if rid in cancelled or closed.is_set():
                    break
                if response.text:
                    send({"id": rid, "text": response.text})
            send({"id": rid, "done": True})
        except Exception as error:  # report it; keep serving
            send({"id": rid, "error": "%s: %s" % (type(error).__name__, error)})
        cancelled.discard(rid)


if __name__ == "__main__":
    main()
