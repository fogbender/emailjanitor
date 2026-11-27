"use strict";
for (const field of document.querySelectorAll('input[name="timezone"]')) {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) field.value = zone;
  } catch (_) { /* The server's UTC fallback remains usable. */ }
}
for (const field of document.querySelectorAll('textarea[name="message"]')) {
  const validate = () => field.setCustomValidity(
    new TextEncoder().encode(field.value).length > 16000
      ? "Keep your message under 16,000 UTF-8 bytes. Your text is still here to edit."
      : ""
  );
  field.addEventListener("input", validate);
  validate();
}
