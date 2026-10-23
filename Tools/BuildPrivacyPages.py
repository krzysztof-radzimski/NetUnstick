#!/usr/bin/env python3
"""Build HTML content materials for the existing ITORG site, plus a local ZIP.

The generated .html files are editable content sources, not the live site's design
or a deployment package. Navigation targets the published canonical URLs. This
script writes only this repository's Distribution/Website and Artifacts folders.
"""
import html
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = json.loads((ROOT / "Tools/LocalizationSource.json").read_text())["strings"]
SPANISH = json.loads((ROOT / "Tools/Translations/western.json").read_text())["es"]
PUBLISHER = "ITORG Krzysztof Radzimski"
CONTACT = "kr@itorg.pl"
SITE = "https://itorg.pl"
PRODUCT_URLS = {
    "pl": f"{SITE}/NetUnstick/",
    "en": f"{SITE}/en/NetUnstick/",
    "es": f"{SITE}/es/NetUnstick/",
}
COPY = {
    "en": {
        "home": "Restore local connections after VPN",
        "intro": "NetUnstick helps when another Mac is visible through Bonjour in Finder but cannot be reached after disconnecting a VPN.",
        "distribution": "NetUnstick is distributed as a Developer ID application. It diagnoses the network and can repair verified stale VPN routes after your confirmation. Repairs require an administrator-approved helper and a check before and after the change.",
        "support": "Support", "privacy": "Privacy policy", "contact": "Contact",
        "mail": "If you email support, ITORG processes the contact details and information you choose to send to answer your request. Send only the details needed; do not send passwords, credentials or unredacted network reports. You may ask about or request deletion of your support correspondence at the same address. Necessary records may be retained to handle the request and legal obligations.",
        "hosting": "The hosting provider may process ordinary web access logs; these static pages contain no analytics scripts or tracking cookies.",
    },
    "pl": {
        "home": "Odzyskaj lokalne połączenia po VPN",
        "intro": "NetUnstick pomaga, gdy po rozłączeniu VPN inny Mac jest widoczny przez Bonjour w Finderze, ale nie można się z nim połączyć.",
        "distribution": "NetUnstick jest dystrybuowany jako aplikacja Developer ID. Diagnozuje sieć i po Twoim potwierdzeniu może naprawić zweryfikowane pozostałe trasy VPN. Naprawy wymagają helpera zatwierdzonego przez administratora i kontroli przed zmianą oraz po niej.",
        "support": "Wsparcie", "privacy": "Polityka prywatności", "contact": "Kontakt",
        "mail": "Jeśli napiszesz do wsparcia, ITORG przetwarza przekazane dane kontaktowe i informacje, aby odpowiedzieć na zgłoszenie. Wysyłaj tylko potrzebne szczegóły; nie przesyłaj haseł, danych logowania ani nieoczyszczonych raportów sieci. Pod tym samym adresem możesz pytać o korespondencję lub prosić o jej usunięcie. Niezbędne zapisy mogą być zachowane w celu obsługi zgłoszenia i obowiązków prawnych.",
        "hosting": "Hosting może przetwarzać zwykłe logi dostępu WWW; te statyczne strony nie zawierają skryptów analitycznych ani śledzących plików cookie.",
    },
    "es": {
        "home": "Recupera las conexiones locales después de la VPN",
        "intro": "NetUnstick ayuda cuando otro Mac aparece mediante Bonjour en Finder, pero no se puede conectar después de desconectar una VPN.",
        "distribution": "NetUnstick se distribuye como aplicación Developer ID. Diagnostica la red y, con tu confirmación, puede reparar rutas residuales de VPN verificadas. Las reparaciones requieren un componente auxiliar autorizado por un administrador y comprobaciones antes y después del cambio.",
        "support": "Soporte", "privacy": "Política de privacidad", "contact": "Contacto",
        "mail": "Si escribes al soporte, ITORG trata los datos de contacto y la información que decidas enviar para responder a tu solicitud. Envía solo los detalles necesarios; no envíes contraseñas, credenciales ni informes de red sin anonimizar. Puedes consultar o solicitar la eliminación de tu correspondencia de soporte en la misma dirección. Los registros necesarios pueden conservarse para atender la solicitud y las obligaciones legales.",
        "hosting": "El alojamiento puede tratar registros normales de acceso web; estas páginas estáticas no contienen scripts de análisis ni cookies de seguimiento.",
    },
}


def page_url(language, page):
    return f"{SITE}/NetUnstick/{language}/{page}"


def navigation(language):
    text = COPY[language]
    links = [(PRODUCT_URLS[language], "NetUnstick")]
    links += [(page_url(language, page), text[page]) for page in ("support", "privacy")]
    return "<nav>" + " · ".join(
        f'<a href="{html.escape(url, quote=True)}">{html.escape(label)}</a>'
        for url, label in links
    ) + "</nav>"


def document(language, title, content, *, render_nav=True):
    nav = navigation(language) if render_nav else ""
    return f'''<!doctype html>
<html lang="{language}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NetUnstick — {html.escape(title)}</title>
<style>:root{{color-scheme:light dark}}body{{font:1.05rem/1.6 system-ui;margin:3rem auto;padding:0 1.5rem;max-width:48rem}}a{{color:inherit}}h1,h2{{line-height:1.25}}nav,footer{{margin:2rem 0}}</style></head>
<body>{nav}<main><h1>NetUnstick — {html.escape(title)}</h1>{content}</main>
<footer>{html.escape(PUBLISHER)} · <a href="mailto:{CONTACT}">{CONTACT}</a></footer></body></html>
'''


def build():
    output = ROOT / "Distribution/Website"
    pages = []
    for language in COPY:
        for page, title, sections in (
            ("privacy", "help_privacy", ["privacy_local", "privacy_network", "privacy_retention", "privacy_permissions", "privacy_version"]),
            ("support", "help_support", ["help_start", "help_scope", "help_support", "help_safety"]),
        ):
            def text(key):
                return html.escape(SPANISH[key] if language == "es" else SOURCE[key][language])
            content = "\n".join(f"<section><h2>{text(key + '_title')}</h2><p>{text(key + '_body')}</p></section>" for key in sections)
            copy = COPY[language]
            content += f'<section><h2>{copy["contact"]}</h2><p><a href="mailto:{CONTACT}">{CONTACT}</a></p><p>{html.escape(copy["mail"])}</p></section>'
            if page == "privacy":
                content += f'<p>{html.escape(copy["hosting"])}</p>'
            path = output / language / f"{page}.html"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(document(language, COPY[language][page], content), encoding="utf-8")
            pages.append(path)
    materials = '<p>Content materials for the existing ITORG product pages. These files do not replace the published website or its design.</p>'
    materials += "<nav>" + " · ".join(
        f'<a href="{PRODUCT_URLS[language]}">{label}</a>'
        for language, label in (("en", "English"), ("pl", "Polski"), ("es", "Español"))
    ) + "</nav>"
    for language, copy in COPY.items():
        materials += f'<section lang="{language}"><h2>{copy["home"]}</h2><p>{copy["intro"]}</p><p>{copy["distribution"]}</p><p><a href="{page_url(language, "support")}">{copy["support"]}</a> · <a href="{page_url(language, "privacy")}">{copy["privacy"]}</a></p></section>'
    index = output / "index.html"
    index.write_text(document("en", "Content materials", materials, render_nav=False), encoding="utf-8")
    pages.append(index)

    archive = ROOT / "Artifacts/Distribution/NetUnstick-Website.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary_archive = archive.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary_archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(pages):
            bundle.write(path, arcname="NetUnstick/" + path.relative_to(output).as_posix())
    temporary_archive.replace(archive)
    print("Prepared 7 HTML content materials in Distribution/Website and Artifacts/Distribution/NetUnstick-Website.zip.")


if __name__ == "__main__":
    build()
