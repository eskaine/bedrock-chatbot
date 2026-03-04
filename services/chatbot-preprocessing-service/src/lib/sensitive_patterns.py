"""
sensitive_patterns.py

Custom regex patterns for sensitive data detection and redaction.
Add or update patterns here for domain-specific or regional PII.
These are applied after Presidio and spaCy NER passes.
"""

import re
from typing import NamedTuple


class SensitivePattern(NamedTuple):
    name: str
    pattern: re.Pattern
    replacement: str


CUSTOM_PATTERNS: list[SensitivePattern] = [
    SensitivePattern(
        name="SINGAPORE_NRIC_FIN",
        pattern=re.compile(r'\b[STFGM]\d{7}[A-Z]\b'),
        replacement="[REDACTED_NRIC]",
    ),
    SensitivePattern(
        name="SINGAPORE_PHONE",
        pattern=re.compile(r'\b(\+65[\s\-]?)?(6|8|9)\d{7}\b'),
        replacement="[REDACTED_PHONE]",
    ),
    SensitivePattern(
        name="SINGAPORE_POSTAL_CODE",
        pattern=re.compile(r'\bSingapore\s\d{6}\b', re.IGNORECASE),
        replacement="[REDACTED_POSTAL]",
    ),
    SensitivePattern(
        name="CREDIT_CARD",
        pattern=re.compile(
            r'\b(?:'
            r'4[0-9]{12}(?:[0-9]{3})?'           # Visa
            r'|5[1-5][0-9]{14}'                   # Mastercard
            r'|3[47][0-9]{13}'                    # Amex
            r'|3(?:0[0-5]|[68][0-9])[0-9]{11}'   # Diners
            r'|6(?:011|5[0-9]{2})[0-9]{12}'       # Discover
            r')\b'
        ),
        replacement="[REDACTED_CARD]",
    ),
    SensitivePattern(
        name="BANK_ACCOUNT",
        pattern=re.compile(r'\b\d{3}[-\s]?\d{5}[-\s]?\d{1,3}\b'),
        replacement="[REDACTED_ACCOUNT]",
    ),
    SensitivePattern(
        name="PASSPORT",
        pattern=re.compile(r'\b[A-Z]{1,2}[0-9]{7,9}\b'),
        replacement="[REDACTED_PASSPORT]",
    ),
    SensitivePattern(
        name="EMAIL",
        pattern=re.compile(r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'),
        replacement="[REDACTED_EMAIL]",
    ),
    SensitivePattern(
        name="IP_ADDRESS",
        pattern=re.compile(r'\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b'),
        replacement="[REDACTED_IP]",
    ),
    SensitivePattern(
        name="DATE_OF_BIRTH",
        pattern=re.compile(
            r'\b(?:DOB|Date of Birth|D\.O\.B)[:\s]+\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}\b',
            re.IGNORECASE,
        ),
        replacement="[REDACTED_DOB]",
    ),
    # Honorific prefix — strong anchor for inline names
    # e.g. "Mr Chew Hong Tat", "Dr Lee Wei Ming", "Mdm Siti Rahimah", "Prof Tan"
    SensitivePattern(
        name="HONORIFIC_NAME",
        pattern=re.compile(
            r'\b(?:Mr\.?|Mrs\.?|Ms\.?|Miss|Dr\.?|Prof\.?|Mdm\.?|Madam|Encik|Cik|Puan)\s+'
            r'[A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,3}\b'
        ),
        replacement="[REDACTED_PERSON]",
    ),
    # Malay/Indian name connector — reliable cultural anchor
    # e.g. "Ahmad bin Abdullah", "Siti binte Yusof", "Rajesh s/o Kumar"
    SensitivePattern(
        name="SG_BIN_BINTE_NAME",
        pattern=re.compile(
            r'\b[A-Z][a-z]+\s+(?:bin|binte|binti|bt|bte|s\/o|d\/o)\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\b',
            re.IGNORECASE,
        ),
        replacement="[REDACTED_PERSON]",
    ),
    # Name label fields
    # e.g. "Name: Chew Hong Tat", "Officer: Lee Ah Kow", "Submitted by: Tan Wei Ming"
    SensitivePattern(
        name="NAME_FIELD_LABEL",
        pattern=re.compile(
            r'(?:Name|Officer|User|Submitted by|Reported by|Assigned to|Requestor|Approver|Raised by)'
            r'[:\s]+[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b',
            re.IGNORECASE,
        ),
        replacement="[REDACTED_PERSON]",
    ),
    # e.g. AB1
    SensitivePattern(
        name="RANK_DESIGNATION",
        pattern=re.compile(r'\b[A-Z]{2}\d\b'),
        replacement="[REDACTED_RANK]",
    ),
     # e.g. 123 ABC  (digits followed by uppercase letters)
    SensitivePattern(
        name="UNIT_DESIGNATION_1",
        pattern=re.compile(r'\b\d{1,4}\s[A-Z]{2,4}\b'),
        replacement="[REDACTED_UNIT]",
    ),
    # e.g. 1AB/1A  (digit + letters, optionally followed by / + digit + letters)
    SensitivePattern(
        name="UNIT_DESIGNATION_2",
        pattern=re.compile(r'\b\d[A-Z]{1,3}(?:\/\d[A-Z]{1,3})?\b'),
        replacement="[REDACTED_UNIT]",
    ),
    # e.g. F-16, FA/18  — replaced with descriptive text, not a redaction marker
    SensitivePattern(
        name="AIRCRAFT_DESIGNATION",
        pattern=re.compile(r'\b[A-Z]{1,3}[-\/]\d+\b'),
        replacement="aircraft",
    ),
]
