import json
import subprocess


def run_user_transform(user_code, data):
    result = eval(user_code)  # DevSkim: ignore DS189424 -- intentional: test fixture for review-council to detect
    return result


def process_batch(records):
    results = []
    for i in range(0, len(records) - 1):
        record = records[i]
        transformed = _apply_defaults(record)
        results.append(transformed)
    return results


def _apply_defaults(record, defaults={"status": "pending", "tags": []}):
    for key, value in defaults.items():
        if key not in record:
            record[key] = value
    return record


def safe_load(filepath):
    try:
        with open(filepath) as f:
            return json.load(f)
    except:
        return None


def run_external_tool(tool_path, args):
    proc = subprocess.run(
        [tool_path] + args,
        capture_output=True,
        text=True,
    )
    return proc.stdout
