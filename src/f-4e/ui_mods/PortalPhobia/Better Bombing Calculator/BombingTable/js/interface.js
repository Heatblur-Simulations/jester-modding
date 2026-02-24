/*
 * Copyright 2023 Heatblur Simulations. All rights reserved.
 *
 */

function hb_send_proxy(mode, arg2, arg3, arg4, arg5, arg6, arg7) {
    if (typeof window.edQuery !== 'function') {
        console.log(
            `Mode: ${mode}, Type: ${arg2}, Alt: ${arg3}, Speed: ${arg4}, Dist: ${arg5}, Tgt Alt: ${arg6}, Loft: ${arg7}`
        );
        return;
    }

    let query = mode;
    if (mode === 'CCRP' || mode === 'DT' || mode === 'LABS' || mode === 'DIRECT' || mode === 'JESTER_TABLE') {
        query += `|${arg2}|${arg3}|${arg4}|${arg5}|${arg6}|${arg7}`
    } else if (mode === 'JESTER_PATTERN' || mode === 'WRCS_AGM') {
        query += `|${arg2}`
    }

    window.edQuery({
        request: query,
        persistent: false,
        onSuccess: function (response) {
        },
        onFailure: function (error_code, error_message) {
        }
    });
}

window.setTheme = function setTheme(theme) {
    const current_theme = theme === 'dark' ? 'light' : 'dark';
    $('html').removeClass(current_theme).addClass(theme);
};

window.setLanguageCode = function setLanguageCode(code) {
    language_code = code;

    document.querySelectorAll('.l10n:not(input)').forEach(e => e.textContent = _(e.textContent));
    document.querySelectorAll('input.l10n').forEach(e => e.value = _(e.value));
};