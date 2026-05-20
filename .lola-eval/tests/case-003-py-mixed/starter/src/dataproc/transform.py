def normalize_record(record):
    name = record.get("name", "")
    email = record.get("email", "")
    return {
        "name": name.strip().title(),
        "email": email.strip().lower(),
        "active": record.get("active", True),
    }


def merge_records(primary, secondary):
    merged = dict(primary)
    for key, value in secondary.items():
        if key not in merged:
            merged[key] = value
    return merged


def validate_email(email):
    return "@" in email and "." in email.split("@")[1]
