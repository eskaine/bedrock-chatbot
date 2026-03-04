"""
pdf_generator.py — converts formatted markdown-style text into a PDF.
"""

import logging
from io import BytesIO

from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer

from shared.exceptions import ServiceError

logger = logging.getLogger(__name__)


def generate_pdf(text: str, title: str = 'Document') -> bytes:
    logger.info("Generating PDF", extra={'title': title})
    try:
        buffer = BytesIO()
        doc = SimpleDocTemplate(
            buffer,
            pagesize=letter,
            rightMargin=inch,
            leftMargin=inch,
            topMargin=inch,
            bottomMargin=inch,
        )

        styles = getSampleStyleSheet()
        story = []

        story.append(Paragraph(title, styles['Title']))
        story.append(Spacer(1, 0.3 * inch))

        for line in text.split('\n'):
            line = line.strip()
            if not line:
                story.append(Spacer(1, 0.1 * inch))
                continue

            if line.startswith('## '):
                story.append(Paragraph(line[3:], styles['Heading2']))
            elif line.startswith('# '):
                story.append(Paragraph(line[2:], styles['Heading1']))
            else:
                story.append(Paragraph(line, styles['BodyText']))

        doc.build(story)
        pdf_bytes = buffer.getvalue()
        logger.info("PDF generated", extra={'size_bytes': len(pdf_bytes)})
        return pdf_bytes
    except Exception as e:
        raise ServiceError("PDF generation failed", context={'error': str(e)}) from e
