let translations = {}
let language_code = 'en'; // Temporarily change the default to ease creation of new translations

function _(text) {
    if (!text) {
        return text;
    }
    // Comment in to find missing translations in the console log
    //if (translations[language_code]?.[text] === undefined) console.log(text)

    return translations[language_code]?.[text] ?? text;
}
