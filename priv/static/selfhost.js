"use strict";
for (const field of document.querySelectorAll('input[name="timezone"]')) {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) field.value = zone;
  } catch (_) { /* The server's UTC fallback remains usable. */ }
}
