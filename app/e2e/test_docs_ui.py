"""Browser regression case (TC-14) — see MANUAL_TEST_PLAN.md."""

from __future__ import annotations

import re

import pytest
from playwright.sync_api import ConsoleMessage, Page, expect

PUBLIC_PATHS = ("/health", "/ready", "/info", "/status")


@pytest.mark.ui
@pytest.mark.case("TC-14")
def test_swagger_ui_lists_public_operations(page: Page) -> None:
    console_errors: list[str] = []

    def on_console(message: ConsoleMessage) -> None:
        if message.type == "error":
            console_errors.append(message.text)

    page.on("console", on_console)

    page.goto("/docs")
    expect(page).to_have_title(re.compile("platform-status"))

    operations = page.locator(".opblock")
    expect(operations).to_have_count(len(PUBLIC_PATHS))
    for path in PUBLIC_PATHS:
        expect(
            page.locator(".opblock-summary-path", has_text=re.compile(rf"^{path}$"))
        ).to_be_visible()

    page.locator(".opblock-summary-path", has_text=re.compile(r"^/health$")).click()
    expect(page.locator(".opblock-body").first).to_be_visible()

    assert console_errors == [], console_errors
