/*
 * Copyright 2023 Heatblur Simulations. All rights reserved.
 *
 */

function hb_send_proxy(action) {
    if (typeof window.edQuery === "function") {
        window.edQuery({
            request: action,
            persistent: false,
            onSuccess: function (response) {
            },
            onFailure: function (error_code, error_message) {
            }
        });
    } else {
        console.log(action)
    }
}
