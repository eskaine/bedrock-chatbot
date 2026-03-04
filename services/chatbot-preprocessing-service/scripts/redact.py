#!/usr/bin/env python3
"""
redact.py — Sensitive data redaction script

Scans documents for sensitive data using three layers:
  1. Microsoft Presidio  — broad PII detection
  2. spaCy NER           — named entity recognition (PERSON, ORG, GPE, LOC)
  3. Custom regex        — regional/domain-specific patterns (src/lib/sensitive_patterns.py)

Writes redacted copies to <output_dir>, preserving the source folder structure.
PDF files are extracted, redacted, and regenerated as PDF.

Usage:
    python3 redact.py                        # defaults: docs/ → docs_redacted/
    python3 redact.py <input_dir> <output_dir>

Supported file types: .txt, .md, .json, .pdf

Dependencies:
    pip install presidio-analyzer presidio-anonymizer spacy pypdf reportlab
    python -m spacy download en_core_web_lg
"""

import sys
import os
import json
from pathlib import Path

# Allow importing from src/lib
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR.parent / 'src'))

# --- Lazy imports with helpful errors ----------------------------------------

def _require(pkg_import, pkg_install, extra=""):
    try:
        return __import__(pkg_import)
    except ImportError:
        print(f"[ERROR] Missing package '{pkg_install}'. Install with:")
        print(f"          pip install {pkg_install}{' ' + extra if extra else ''}")
        sys.exit(1)


# Presidio
presidio_analyzer_mod  = _require("presidio_analyzer",   "presidio-analyzer")
presidio_anonymizer_mod = _require("presidio_anonymizer", "presidio-anonymizer")
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig

# spaCy
spacy_mod = _require("spacy", "spacy", "  # then: python -m spacy download en_core_web_lg")
import spacy

# Custom patterns
from lib.sensitive_patterns import CUSTOM_PATTERNS

# --- Initialise models --------------------------------------------------------

print("[INIT] Loading spaCy model...")
try:
    nlp = spacy.load("en_core_web_lg")
    print("[INIT] Loaded en_core_web_lg")
except OSError:
    try:
        nlp = spacy.load("en_core_web_sm")
        print("[INIT] Loaded en_core_web_sm (en_core_web_lg not found)")
    except OSError:
        print("[ERROR] No spaCy English model found. Run:")
        print("          python -m spacy download en_core_web_lg")
        sys.exit(1)

analyzer  = AnalyzerEngine()
anonymizer = AnonymizerEngine()

PRESIDIO_ENTITIES = [
    "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "CREDIT_CARD",
    "IBAN_CODE", "IP_ADDRESS", "LOCATION", "DATE_TIME", "NRP",
    "MEDICAL_LICENSE", "URL", "US_SSN", "US_BANK_NUMBER",
]

SPACY_REDACT_LABELS = {"PERSON", "ORG", "GPE", "LOC"}

# --- Redaction logic ----------------------------------------------------------

def redact_text(text: str) -> str:
    """Apply all three redaction layers to plain text."""
    if not text.strip():
        return text

    # Layer 1: Presidio
    results = analyzer.analyze(text=text, entities=PRESIDIO_ENTITIES, language="en")
    if results:
        operators = {
            entity: OperatorConfig("replace", {"new_value": f"[REDACTED_{entity}]"})
            for entity in PRESIDIO_ENTITIES
        }
        text = anonymizer.anonymize(
            text=text,
            analyzer_results=results,
            operators=operators,
        ).text

    # Layer 2: spaCy NER — catch entities Presidio may have missed
    doc = nlp(text)
    replacements = [
        (ent.start_char, ent.end_char, f"[REDACTED_{ent.label_}]")
        for ent in doc.ents
        if ent.label_ in SPACY_REDACT_LABELS
    ]
    for start, end, replacement in sorted(replacements, reverse=True):
        text = text[:start] + replacement + text[end:]

    # Layer 3: Custom regex patterns
    for pattern in CUSTOM_PATTERNS:
        text = pattern.pattern.sub(pattern.replacement, text)

    return text


def redact_json(data) -> object:
    """Recursively redact string values in a JSON structure."""
    if isinstance(data, str):
        return redact_text(data)
    if isinstance(data, dict):
        return {k: redact_json(v) for k, v in data.items()}
    if isinstance(data, list):
        return [redact_json(item) for item in data]
    return data


def process_file(input_path: Path, output_path: Path):
    """Redact a single file and write the result to output_path."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    suffix = input_path.suffix.lower()

    if suffix in (".txt", ".md"):
        text = input_path.read_text(encoding="utf-8")
        output_path.write_text(redact_text(text), encoding="utf-8")

    elif suffix == ".json":
        data = json.loads(input_path.read_text(encoding="utf-8"))
        output_path.write_text(json.dumps(redact_json(data), indent=2), encoding="utf-8")

    elif suffix == ".pdf":
        try:
            from pypdf import PdfReader
            from reportlab.lib.pagesizes import letter
            from reportlab.lib.styles import getSampleStyleSheet
            from reportlab.lib.units import inch
            from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
        except ImportError as e:
            print(f"[ERROR] Missing dependency: {e}. Run: pip install pypdf reportlab")
            sys.exit(1)

        reader = PdfReader(str(input_path))
        raw_text = "\n".join(
            page.extract_text() for page in reader.pages if page.extract_text()
        )
        redacted_text = redact_text(raw_text)

        # Regenerate as PDF
        from io import BytesIO
        buffer = BytesIO()
        doc = SimpleDocTemplate(buffer, pagesize=letter,
                                rightMargin=inch, leftMargin=inch,
                                topMargin=inch, bottomMargin=inch)
        styles = getSampleStyleSheet()
        story = []

        # pypdf inserts a newline after almost every word/phrase.
        # Fix: single \n → space (word wrap), double \n → paragraph break.
        import re
        normalized = re.sub(r'\n\n+', '\x00', redacted_text)
        normalized = normalized.replace('\n', ' ')
        normalized = re.sub(r' +', ' ', normalized)
        para_blocks = [p.strip() for p in normalized.split('\x00')]

        for para in para_blocks:
            if not para:
                story.append(Spacer(1, 0.1 * inch))
            elif para.startswith("## "):
                story.append(Paragraph(para[3:], styles["Heading2"]))
            elif para.startswith("# "):
                story.append(Paragraph(para[2:], styles["Heading1"]))
            else:
                story.append(Paragraph(para, styles["BodyText"]))
                story.append(Spacer(1, 0.1 * inch))

        doc.build(story)
        output_path.write_bytes(buffer.getvalue())
        print(f"  [PDF→PDF] {input_path.name}")

    else:
        print(f"  [SKIP] Unsupported type: {input_path.name}")
        return

    print(f"  [OK] {input_path.name}")


# --- Main --------------------------------------------------------------------

def main():
    input_dir  = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (SCRIPT_DIR.parent / 'raw').resolve()
    output_dir = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else (SCRIPT_DIR.parent / 'docs').resolve()

    if not input_dir.is_dir():
        print(f"[ERROR] Input directory not found: {input_dir}")
        sys.exit(1)

    supported = {".txt", ".md", ".json", ".pdf"}
    files = sorted(f for f in input_dir.rglob("*") if f.is_file() and f.suffix.lower() in supported)

    if not files:
        print(f"[WARN] No supported files found in {input_dir}")
        sys.exit(0)

    print(f"[INFO] Redacting {len(files)} file(s)...")
    print(f"[INFO] Output → {output_dir}")
    print()

    ok = 0
    failed = 0
    for f in files:
        relative = f.relative_to(input_dir)
        out = output_dir / relative
        try:
            process_file(f, out)
            ok += 1
        except Exception as e:
            print(f"  [ERROR] {f.name}: {e}")
            failed += 1

    print()
    print("=========================================")
    print(f"Redacted : {ok}")
    if failed:
        print(f"Failed   : {failed}")
    print("=========================================")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
