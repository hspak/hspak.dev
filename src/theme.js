const storageKey = "theme-invert";

function loadInvert() {
    try {
        return localStorage.getItem(storageKey) === "1";
    } catch {
        return false;
    }
}

function saveInvert(on) {
    try {
        if (on) localStorage.setItem(storageKey, "1");
        else localStorage.removeItem(storageKey);
    } catch {}
}

function applyInvert(on) {
    document.documentElement.classList.toggle("theme-invert", on);
}

applyInvert(loadInvert());

document.addEventListener("DOMContentLoaded", () => {
    const box = document.getElementById("theme");
    if (!box) return;
    box.checked = loadInvert();
    box.addEventListener("change", () => {
        saveInvert(box.checked);
        applyInvert(box.checked);
    });
});
