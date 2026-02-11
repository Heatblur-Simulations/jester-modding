/**
 *  Grease Pencil – Enhanced F-4E UI Mod
 *  Core rendering based on the original Heatblur implementation
 *  (SpritePool + drawBuffer + ticker batched rendering).
 *
 *  Enhancements: Shape tools, 2 Layers, Undo/Redo,
 *                Save/Load, Image stamps, Custom import.
 */

// ── Constants ─────────────────────────────────────────────────
var stage_width  = 1024;
var stage_height = 1024;
var MAX_UNDO     = 30;
var NUM_LAYERS   = 2;

// ── State ─────────────────────────────────────────────────────
var drawing        = false;
var lastPosition   = null;
var shapeStartPos  = null;
var activeLayerIndex = 0;
var undoStack      = [];
var redoStack      = [];
var placedImages   = [];
var availableImages = [];
var brush_size     = 0;   // computed by updateBrush()
var brushTexture   = null;

// ── Config (mirrors HTML controls) ────────────────────────────
var config = {
    tool:            'Brush',
    draw_brush_size:  12,
    erase_brush_size: 50,
    brushColor:       0x000000,  // default black
    fillShapes:       false,
    imageSize:        300,
    imageOpacity:     1,
    imageRotation:    0,
};

// ══════════════════════════════════════════════════════════════
//  Heatblur integration  (hideGui / showGui / hb_send_proxy)
// ══════════════════════════════════════════════════════════════
window.hideGui = function hideGui() {
    var panel = document.getElementById('controlPanel');
    if (panel) panel.style.display = 'none';

    // Unlock keyboard when closing
    unlockKeyboardFromDCS();
    
    setTimeout(function() {
        hb_send_proxy("close");
    }, 100);
};

window.showGui = function showGui() {
    var panel = document.getElementById('controlPanel');
    if (panel) panel.style.display = 'block';
    
    // Lock keyboard when opening grease pencil
    lockKeyboardForDCS();
};

// Keyboard lock/unlock for DCS - try multiple approaches
function lockKeyboardForDCS() {
    // Try various DCS keyboard lock commands
    if (typeof window.edQuery === "function") {
        // Method 1: lockKeyboard command
        try {
            window.edQuery({ request: "lockKeyboard", persistent: true });
        } catch(e) {}
        
        // Method 2: keyboardLock
        try {
            window.edQuery({ request: "keyboardLock", persistent: true });
        } catch(e) {}
        
        // Method 3: captureKeyboard
        try {
            window.edQuery({ request: "captureKeyboard" });
        } catch(e) {}
    }
    
    // Also set document property that some game engines check
    document.body.setAttribute('data-keyboard-capture', 'true');
    
    console.log("Grease Pencil: Keyboard lock requested");
}

function unlockKeyboardFromDCS() {
    if (typeof window.edQuery === "function") {
        try {
            window.edQuery({ request: "unlockKeyboard", persistent: false });
        } catch(e) {}
        
        try {
            window.edQuery({ request: "keyboardUnlock", persistent: false });
        } catch(e) {}
        
        try {
            window.edQuery({ request: "releaseKeyboard" });
        } catch(e) {}
    }
    
    document.body.removeAttribute('data-keyboard-capture');
    
    console.log("Grease Pencil: Keyboard unlock requested");
}

// ── DOM helper ────────────────────────────────────────────────
function $(id) { return document.getElementById(id); }

// ══════════════════════════════════════════════════════════════
//  PIXI Application  (matches original: resizeTo window)
// ══════════════════════════════════════════════════════════════
var app = new PIXI.Application({
    background: '#40363a',
    backgroundAlpha: 0,
    resizeTo: window,
    antialias: true,
    forceCanvas: true,
});
document.body.appendChild(app.view);

// ── SpritePool + DrawBuffer (original rendering engine) ──────
var spritePool = new SpritePool();
var drawBuffer = new PIXI.Container();

// ── Layer System ──────────────────────────────────────────────
var layers = [];

for (var i = 0; i < NUM_LAYERS; i++) {
    var rt  = PIXI.RenderTexture.create({ width: stage_width, height: stage_height });
    var spr = new PIXI.Sprite(rt);
    spr.anchor.set(0.5);
    spr.width  = stage_width;
    spr.height = stage_height;
    spr.position.set(stage_width / 2, stage_height / 2);
    spr.interactive = (i === 0);
    if (i === 0) spr.eventMode = 'static';
    spr.alpha = 0.8;
    app.stage.addChild(spr);
    layers.push({ renderTexture: rt, sprite: spr, visible: true });
}

// The bottom layer sprite captures all drawing input
var inputSprite = layers[0].sprite;

// Shape preview overlay (for live line/circle/rect while dragging)
var shapePreview = new PIXI.Graphics();
app.stage.addChild(shapePreview);

function activeRT() { return layers[activeLayerIndex].renderTexture; }

// ══════════════════════════════════════════════════════════════
//  Brush texture generation  (from original updateBrush)
// ══════════════════════════════════════════════════════════════
function updateBrush() {
    brush_size = (config.tool === 'Eraser') ? config.erase_brush_size : config.draw_brush_size;

    var brush = new PIXI.Graphics();
    brush.beginFill(config.brushColor)
        .drawCircle(0, 0, brush_size / 2)
        .endFill();
    brushTexture = app.renderer.generateTexture(brush);
}
updateBrush();   // initial

// ══════════════════════════════════════════════════════════════
//  Drawing helpers  (SpritePool approach from original)
// ══════════════════════════════════════════════════════════════
function drawPoint(x, y) {
    var s = spritePool.get();
    s.x = x;
    s.y = y;
    s.texture = brushTexture;

    if (config.tool === 'Eraser') {
        s.filter = new PIXI.AlphaFilter();
        s.blendMode = PIXI.BLEND_MODES.ERASE;
    } else {
        s.filter = null;
        s.blendMode = PIXI.BLEND_MODES.NORMAL;
    }

    drawBuffer.addChild(s);
}

function drawPointLine(oldPos, newPos) {
    var delta = {
        x: oldPos.x - newPos.x,
        y: oldPos.y - newPos.y,
    };
    var deltaLength = Math.sqrt(delta.x * delta.x + delta.y * delta.y);

    drawPoint(newPos.x, newPos.y);

    if (deltaLength >= brush_size / 8) {
        var additionalPoints = Math.ceil(deltaLength / (brush_size / 8));
        for (var i = 1; i < additionalPoints; i++) {
            var pos = {
                x: newPos.x + delta.x * (i / additionalPoints),
                y: newPos.y + delta.y * (i / additionalPoints),
            };
            drawPoint(pos.x, pos.y);
        }
    }
}

function renderPoints() {
    if (drawBuffer.children.length === 0) return;
    app.renderer.render(drawBuffer, { "renderTexture": activeRT(), "clear": false });
    drawBuffer.removeChildren();
    spritePool.reset();
}

// Ticker: batch-render brush dots every frame (original approach)
app.ticker.add(function() {
    renderPoints();
});

// ══════════════════════════════════════════════════════════════
//  Tool helpers
// ══════════════════════════════════════════════════════════════
function getBrushColor() {
    return config.brushColor;
}
function isShapeTool() {
    return config.tool === 'Line' || config.tool === 'Circle' || config.tool === 'Rectangle' || config.tool === 'Bubble' || config.tool === 'Crosshair' || config.tool === 'Circleplus' || config.tool === 'Bullseye' || config.tool === 'CircleCross';
}

// ══════════════════════════════════════════════════════════════
//  Text Tool  (Photoshop-style: type, drag to position, commit)
// ══════════════════════════════════════════════════════════════
var textInputOverlay = null;
var pendingTextPos = null;
var placedText = null;  // Currently placed text sprite (draggable)

function showTextInput(x, y) {
    if (textInputOverlay) removeTextInput();
    pendingTextPos = { x: x, y: y };

    // ═══════════════════════════════════════════════════════════
    //  On-screen virtual keyboard — guaranteed to work in DCS
    //  because it uses only mouse clicks, no keyboard events.
    // ═══════════════════════════════════════════════════════════
    var textBuffer = '';
    var cursorPos = 0;
    var shifted = false;
    var capsLock = false;
    var textColorHex = '#' + ('000000' + config.brushColor.toString(16)).slice(-6);

    textInputOverlay = document.createElement('div');
    textInputOverlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:transparent;z-index:9999;';

    var box = document.createElement('div');
    box.style.cssText = 'position:absolute;background:rgba(0,0,0,0.65);border:1px solid #695457;border-radius:3px;padding:8px;min-width:465px;box-shadow:0 0 12px rgba(0,0,0,0.4);cursor:default;overflow:hidden;';
    // Center initially
    box.style.left = Math.max(0, (window.innerWidth - 465) / 2) + 'px';
    box.style.top = Math.max(0, (window.innerHeight - 340) / 2) + 'px';

    // ── Drag handle (title bar) ──
    var dragHandle = document.createElement('div');
    dragHandle.textContent = '⣿⣿ Drag to move ⣿⣿';
    dragHandle.style.cssText = 'text-align:center;color:#f5c842;font-family:Consolas,monospace;font-size:8px;padding:1px 0 3px;cursor:grab;user-select:none;margin-bottom:3px;border-bottom:1px solid #4a353888;';

    // Drag logic
    var dragState = { dragging: false, offX: 0, offY: 0 };
    dragHandle.onmousedown = function(e) {
        e.preventDefault();
        dragState.dragging = true;
        dragState.offX = e.clientX - box.offsetLeft;
        dragState.offY = e.clientY - box.offsetTop;
        dragHandle.style.cursor = 'grabbing';
    };
    // Store refs for cleanup
    textInputOverlay._dragMove = function(e) {
        if (!dragState.dragging) return;
        box.style.left = (e.clientX - dragState.offX) + 'px';
        box.style.top = (e.clientY - dragState.offY) + 'px';
    };
    textInputOverlay._dragUp = function() {
        dragState.dragging = false;
        dragHandle.style.cursor = 'grab';
    };
    document.addEventListener('mousemove', textInputOverlay._dragMove);
    document.addEventListener('mouseup', textInputOverlay._dragUp);

    // ── Label + Text Color picker in one row ──
    var labelRow = document.createElement('div');
    labelRow.style.cssText = 'display:flex;align-items:center;justify-content:space-between;margin-bottom:4px;';

    var label = document.createElement('span');
    label.textContent = 'Enter text for the canvas:';
    label.style.cssText = 'color:#b3b3b3;font-family:Consolas,monospace;font-size:9px;';
    labelRow.appendChild(label);

    var textColorConfig = { textColor: parseInt(textColorHex.replace('#', ''), 16) };
    var textColorGui = new dat.GUI({ autoPlace: false });
    var textColorCtrl = textColorGui.addColor(textColorConfig, 'textColor').name('Text Color');
    textColorCtrl.onChange(function(value) {
        var intVal = (typeof value === 'number') ? value : parseInt(value);
        textColorHex = '#' + ('000000' + intVal.toString(16)).slice(-6);
        display.style.color = textColorHex;
    });

    // Remove the Close Controls button and slim down the GUI
    var guiEl = textColorGui.domElement;
    guiEl.style.cssText = 'display:inline-block;';
    var closeBtn = guiEl.querySelector('.close-button');
    if (closeBtn) closeBtn.style.display = 'none';
    // Remove title bar if present
    var titleBar = guiEl.querySelector('.title');
    if (titleBar) titleBar.style.display = 'none';
    labelRow.appendChild(guiEl);

    // ── Text display area ──
    var display = document.createElement('div');
    display.style.cssText = [
        'width:100%;min-height:32px;max-height:60px;overflow-y:auto;',
        'box-sizing:border-box;padding:4px 6px;margin-bottom:6px;',
        'background:rgba(200,200,200,0.5);color:#111111;',
        'border:1px solid #695457;border-radius:3px;',
        'font-family:Caveat,Arial,sans-serif;font-size:14px;',
        'white-space:pre-wrap;word-wrap:break-word;line-height:1.3;'
    ].join('');

    var cursorSpan = document.createElement('span');
    cursorSpan.textContent = '|';
    cursorSpan.style.cssText = 'color:#a50a45;animation:vkBlink 1s step-end infinite;';
    var blinkStyle = document.createElement('style');
    blinkStyle.textContent = '@keyframes vkBlink{0%,100%{opacity:1}50%{opacity:0}}';

    function updateDisplay() {
        display.textContent = '';
        var before = textBuffer.slice(0, cursorPos);
        var after  = textBuffer.slice(cursorPos);
        if (before) display.appendChild(document.createTextNode(before));
        display.appendChild(cursorSpan);
        if (after) display.appendChild(document.createTextNode(after));
        display.scrollTop = display.scrollHeight;
    }

    function insertAtCursor(ch) {
        textBuffer = textBuffer.slice(0, cursorPos) + ch + textBuffer.slice(cursorPos);
        cursorPos += ch.length;
        updateDisplay();
    }

    function deleteAtCursor() {
        if (cursorPos > 0) {
            textBuffer = textBuffer.slice(0, cursorPos - 1) + textBuffer.slice(cursorPos);
            cursorPos--;
            updateDisplay();
        }
    }

    // ── Button press flash highlight ──
    function flashKey(btn) {
        var orig = btn.style.borderColor;
        btn.style.borderColor = '#f5c842';
        setTimeout(function() { btn.style.borderColor = orig; }, 150);
    }

    updateDisplay();

    // ── Key styles (compact) ──
    var K = 'display:inline-flex;align-items:center;justify-content:center;min-width:21px;height:21px;margin:1px;padding:0 3px;background:#000000;color:#f5c842;border:1px solid #4a3538;border-radius:2px;cursor:pointer;font-family:Consolas,monospace;font-size:10px;user-select:none;';
    var S = K + 'background:#111111;color:#ffe566;font-size:8px;';

    // ── Layout ──
    // Symbols: Page 1 (punctuation/math) and Page 2 (special/tactical)
    var symPage1Row1 = [['°','°'],["'","'"],['″','″'],['!','!'],['@','@'],['#','#'],['$','$'],['%','%'],['&','&'],['*','*']];
    var symPage1Row2 = [['(','('],[')',')'],['-','_'],['=','+'],['[',']'],['\\','/'],[';',':'],['.',','],['?','?']];

    var symPage2Row1 = [['✛','✛'],['⊕','⊕'],['◎','◎'],['∿','∿'],['△','△'],['▽','▽'],['◇','◇'],['←','←'],['→','→'],['↑','↑']];
    var symPage2Row2 = [['↓','↓'],['⊗','⊗'],['⊘','⊘'],['≈','≈'],['±','±'],['·','·'],['×','×'],['÷','÷'],['√','√'],['∞','∞']];

    // Letter rows
    var letterRows = [
        [['q','Q'],['w','W'],['e','E'],['r','R'],['t','T'],['y','Y'],['u','U'],['i','I'],['o','O'],['p','P']],
        [['a','A'],['s','S'],['d','D'],['f','F'],['g','G'],['h','H'],['j','J'],['k','K'],['l','L']],
        [['z','Z'],['x','X'],['c','C'],['v','V'],['b','B'],['n','N'],['m','M']]
    ];

    // Numpad
    var numRows = [['7','8','9'],['4','5','6'],['1','2','3'],['0','.','+']];

    // ── Wrapper: left=letters, right=numpad ──
    var wrapper = document.createElement('div');
    wrapper.style.cssText = 'display:flex;gap:4px;';

    var leftSide = document.createElement('div');
    leftSide.style.cssText = 'flex:1;';

    var rightSide = document.createElement('div');
    rightSide.style.cssText = 'border-left:1px solid #4a353866;padding-left:4px;display:flex;flex-direction:column;align-items:center;';

    // ── Helper: make a key button ──
    function isUpper() { return shifted !== capsLock; }
    var shiftIndicator = null;
    var capsIndicator = null;

    function refreshKeyLabels() {
        var upper = isUpper();
        var allKeys = wrapper.querySelectorAll('[data-lower]');
        for (var i = 0; i < allKeys.length; i++) {
            var k = allKeys[i];
            k.textContent = upper ? k.dataset.upper : k.dataset.lower;
        }
        if (shiftIndicator) { shiftIndicator.style.background = shifted ? '#a50a45' : '#29151A'; shiftIndicator.style.color = shifted ? '#fff' : '#d4d4d4'; }
        if (capsIndicator) { capsIndicator.style.background = capsLock ? '#a50a45' : '#29151A'; capsIndicator.style.color = capsLock ? '#fff' : '#d4d4d4'; }
    }

    function makeKey(pair) {
        var btn = document.createElement('div');
        btn.dataset.lower = pair[0];
        btn.dataset.upper = pair[1];
        btn.textContent = pair[0];
        btn.style.cssText = K;
        btn.onmousedown = function(e) { e.preventDefault(); };
        btn.onclick = function() {
            flashKey(btn);
            insertAtCursor(isUpper() ? pair[1] : pair[0]);
            if (shifted) { shifted = false; refreshKeyLabels(); }
        };
        return btn;
    }

    function makeRow(keys) {
        var row = document.createElement('div');
        row.style.cssText = 'display:flex;justify-content:center;';
        keys.forEach(function(pair) { row.appendChild(makeKey(pair)); });
        return row;
    }

    // ── Symbol rows (paged) ──
    var symContainer = document.createElement('div');
    var symCurrentPage = 1;

    var symR1_p1 = makeRow(symPage1Row1);
    var symR2_p1 = makeRow(symPage1Row2);
    var symR1_p2 = makeRow(symPage2Row1);
    var symR2_p2 = makeRow(symPage2Row2);
    symR1_p2.style.display = 'none';
    symR2_p2.style.display = 'none';

    symContainer.appendChild(symR1_p1);
    symContainer.appendChild(symR2_p1);
    symContainer.appendChild(symR1_p2);
    symContainer.appendChild(symR2_p2);
    leftSide.appendChild(symContainer);

    // ── Divider + page toggle button ──
    var dividerRow = document.createElement('div');
    dividerRow.style.cssText = 'display:flex;align-items:center;gap:4px;margin:3px 0;';

    var divLeft = document.createElement('div');
    divLeft.style.cssText = 'flex:1;height:1px;background:#4a353888;';
    var divRight = document.createElement('div');
    divRight.style.cssText = 'flex:1;height:1px;background:#4a353888;';

    var symPageBtn = document.createElement('div');
    symPageBtn.textContent = 'Sym 2';
    symPageBtn.style.cssText = S + 'min-width:40px;font-size:7px;padding:1px 4px;';
    symPageBtn.onmousedown = function(e) { e.preventDefault(); };
    symPageBtn.onclick = function() {
        flashKey(symPageBtn);
        if (symCurrentPage === 1) {
            symCurrentPage = 2;
            symR1_p1.style.display = 'none'; symR2_p1.style.display = 'none';
            symR1_p2.style.display = 'flex'; symR2_p2.style.display = 'flex';
            symPageBtn.textContent = 'Sym 1';
        } else {
            symCurrentPage = 1;
            symR1_p1.style.display = 'flex'; symR2_p1.style.display = 'flex';
            symR1_p2.style.display = 'none'; symR2_p2.style.display = 'none';
            symPageBtn.textContent = 'Sym 2';
        }
    };

    dividerRow.appendChild(divLeft);
    dividerRow.appendChild(symPageBtn);
    dividerRow.appendChild(divRight);
    leftSide.appendChild(dividerRow);

    // ── Letter rows ──
    // Row 1: QWERTY + Backspace
    var qRow = makeRow(letterRows[0]);
    var bksp = document.createElement('div');
    bksp.textContent = '⌫';
    bksp.style.cssText = S + 'min-width:27px;';
    bksp.onmousedown = function(e) { e.preventDefault(); };
    bksp.onclick = function() { flashKey(bksp); deleteAtCursor(); };
    qRow.appendChild(bksp);
    leftSide.appendChild(qRow);

    // Row 2: Caps + ASDF
    var aRow = document.createElement('div');
    aRow.style.cssText = 'display:flex;justify-content:center;';
    var capsBtn = document.createElement('div');
    capsBtn.textContent = 'Caps';
    capsBtn.style.cssText = S + 'min-width:28px;';
    capsBtn.onmousedown = function(e) { e.preventDefault(); };
    capsBtn.onclick = function() { flashKey(capsBtn); capsLock = !capsLock; refreshKeyLabels(); };
    capsIndicator = capsBtn;
    aRow.appendChild(capsBtn);
    letterRows[1].forEach(function(pair) { aRow.appendChild(makeKey(pair)); });
    leftSide.appendChild(aRow);

    // Row 3: Shift + ZXCV
    var zRow = document.createElement('div');
    zRow.style.cssText = 'display:flex;justify-content:center;';
    var shiftBtn = document.createElement('div');
    shiftBtn.textContent = 'Shift';
    shiftBtn.style.cssText = S + 'min-width:32px;';
    shiftBtn.onmousedown = function(e) { e.preventDefault(); };
    shiftBtn.onclick = function() { flashKey(shiftBtn); shifted = !shifted; refreshKeyLabels(); };
    shiftIndicator = shiftBtn;
    zRow.appendChild(shiftBtn);
    letterRows[2].forEach(function(pair) { zRow.appendChild(makeKey(pair)); });
    leftSide.appendChild(zRow);

    // ── Bottom row: Clear, Space, Enter ──
    var botRow = document.createElement('div');
    botRow.style.cssText = 'display:flex;justify-content:center;margin-top:2px;';

    var clearBtn = document.createElement('div');
    clearBtn.textContent = 'Clear';
    clearBtn.style.cssText = S + 'min-width:30px;background:#3a1515;border-color:#e17f7f;color:#e17f7f;';
    clearBtn.onmousedown = function(e) { e.preventDefault(); };
    clearBtn.onclick = function() { flashKey(clearBtn); textBuffer = ''; cursorPos = 0; updateDisplay(); };

    var leftArrow = document.createElement('div');
    leftArrow.textContent = '◀';
    leftArrow.style.cssText = S + 'min-width:22px;font-size:9px;';
    leftArrow.onmousedown = function(e) { e.preventDefault(); };
    leftArrow.onclick = function() { flashKey(leftArrow); if (cursorPos > 0) { cursorPos--; updateDisplay(); } };

    var spaceBtn = document.createElement('div');
    spaceBtn.textContent = 'Space';
    spaceBtn.style.cssText = S + 'min-width:105px;';
    spaceBtn.onmousedown = function(e) { e.preventDefault(); };
    spaceBtn.onclick = function() { flashKey(spaceBtn); insertAtCursor(' '); };

    var rightArrow = document.createElement('div');
    rightArrow.textContent = '▶';
    rightArrow.style.cssText = S + 'min-width:22px;font-size:9px;';
    rightArrow.onmousedown = function(e) { e.preventDefault(); };
    rightArrow.onclick = function() { flashKey(rightArrow); if (cursorPos < textBuffer.length) { cursorPos++; updateDisplay(); } };

    var enterBtn = document.createElement('div');
    enterBtn.textContent = 'ENT';
    enterBtn.style.cssText = S + 'min-width:34px;font-size:9px;font-weight:bold;background:#4b5320;border-color:#6b7a2e;color:#ffffff;';
    enterBtn.onmousedown = function(e) { e.preventDefault(); };
    enterBtn.onclick = function() { flashKey(enterBtn); insertAtCursor('\n'); };

    botRow.appendChild(clearBtn);
    botRow.appendChild(leftArrow);
    botRow.appendChild(spaceBtn);
    botRow.appendChild(rightArrow);
    botRow.appendChild(enterBtn);
    leftSide.appendChild(botRow);

    // ── Numpad (right side) ──
    var numCol = document.createElement('div');
    numCol.style.cssText = 'display:flex;flex-direction:column;align-items:center;';

    var numLabel = document.createElement('div');
    numLabel.textContent = 'Numpad';
    numLabel.style.cssText = 'color:#898989;font-family:Consolas,monospace;font-size:8px;margin-bottom:1px;';
    numCol.appendChild(numLabel);

    numRows.forEach(function(nr) {
        var row = document.createElement('div');
        row.style.cssText = 'display:flex;justify-content:center;';
        nr.forEach(function(n) {
            var btn = document.createElement('div');
            btn.textContent = n;
            btn.style.cssText = K + 'min-width:24px;';
            btn.onmousedown = function(e) { e.preventDefault(); };
            btn.onclick = function() { flashKey(btn); insertAtCursor(n); };
            row.appendChild(btn);
        });
        numCol.appendChild(row);
    });

    var numBksp = document.createElement('div');
    numBksp.textContent = '⌫';
    numBksp.style.cssText = S + 'min-width:75px;margin-top:1px;';
    numBksp.onmousedown = function(e) { e.preventDefault(); };
    numBksp.onclick = function() { flashKey(numBksp); deleteAtCursor(); };
    numCol.appendChild(numBksp);

    rightSide.appendChild(numCol);

    wrapper.appendChild(leftSide);
    wrapper.appendChild(rightSide);

    // ── Action buttons ──
    var btnRow = document.createElement('div');
    btnRow.style.cssText = 'display:flex;gap:6px;margin-top:6px;';

    var okBtn = document.createElement('button');
    okBtn.textContent = 'Add Text';
    okBtn.style.cssText = 'flex:1;padding:5px;background:#000000;color:#f5c842;border:1px solid #a50a45;border-radius:2px;cursor:pointer;font-family:Consolas,monospace;font-size:10px;font-weight:bold;';
    okBtn.onclick = function() {
        if (textBuffer.trim()) { placeTextDirectly(textBuffer, textColorHex); }
        removeTextInput();
    };

    var cancelBtn = document.createElement('button');
    cancelBtn.textContent = 'Cancel';
    cancelBtn.style.cssText = 'flex:1;padding:5px;background:#000000;color:#f5c842;border:1px solid #695457;border-radius:2px;cursor:pointer;font-family:Consolas,monospace;font-size:10px;';
    cancelBtn.onclick = removeTextInput;

    btnRow.appendChild(okBtn);
    btnRow.appendChild(cancelBtn);

    // ── Assemble ──
    box.appendChild(blinkStyle);
    box.appendChild(dragHandle);
    box.appendChild(labelRow);
    box.appendChild(display);
    box.appendChild(wrapper);
    box.appendChild(btnRow);

    // ── Resize grip (bottom-right corner) ──
    var resizeGrip = document.createElement('div');
    resizeGrip.textContent = '◢';
    resizeGrip.style.cssText = 'position:absolute;bottom:0;right:0;width:16px;height:16px;cursor:nwse-resize;color:#f5c842;font-size:12px;line-height:16px;text-align:center;user-select:none;-webkit-user-select:none;';
    var resizeState = { resizing: false, startX: 0, startY: 0, startW: 0, startH: 0 };
    resizeGrip.onmousedown = function(e) {
        e.preventDefault();
        e.stopPropagation();
        resizeState.resizing = true;
        resizeState.startX = e.clientX;
        resizeState.startY = e.clientY;
        resizeState.startW = box.offsetWidth;
        resizeState.startH = box.offsetHeight;
    };
    textInputOverlay._resizeMove = function(e) {
        if (!resizeState.resizing) return;
        var newW = Math.max(465, resizeState.startW + (e.clientX - resizeState.startX));
        var newH = Math.max(200, resizeState.startH + (e.clientY - resizeState.startY));
        box.style.width = newW + 'px';
        box.style.height = newH + 'px';
    };
    textInputOverlay._resizeUp = function() {
        resizeState.resizing = false;
    };
    document.addEventListener('mousemove', textInputOverlay._resizeMove);
    document.addEventListener('mouseup', textInputOverlay._resizeUp);
    box.appendChild(resizeGrip);

    textInputOverlay.appendChild(box);
    textInputOverlay._textColorGui = textColorGui;
    document.body.appendChild(textInputOverlay);
}

// Place text directly from a string
function placeTextDirectly(text, overrideColor) {
    if (placedText) {
        app.stage.removeChild(placedText);
        placedText.destroy();
        placedText = null;
    }

    var fontSize = Math.max(12, config.draw_brush_size * 2);
    var colorHex = overrideColor || ('#' + ('000000' + config.brushColor.toString(16)).slice(-6));
    var scaleFactor = 2;

    placedText = new PIXI.Text(text, {
        fontFamily: 'Caveat, Arial, sans-serif',
        fontSize: fontSize * scaleFactor,
        fill: colorHex,
        fontWeight: '500',
        padding: Math.max(10, fontSize * 0.3),
        stroke: colorHex,
        strokeThickness: 0.3 * scaleFactor,
        miterLimit: 2
    });
    placedText.scale.set(1 / scaleFactor);
    placedText.position.set(pendingTextPos.x, pendingTextPos.y);
    placedText.anchor.set(0.5, 0.5);

    placedText.interactive = true;
    placedText.cursor = 'move';
    placedText.on('pointerdown', textDragStart);
    placedText.on('pointerup', textDragEnd);
    placedText.on('pointerupoutside', textDragEnd);
    placedText.on('pointermove', textDragMove);

    app.stage.addChild(placedText);
    updateTextControls();
}

function removeTextInput() {
    if (textInputOverlay) {
        // Clean up drag listeners
        if (textInputOverlay._dragMove) document.removeEventListener('mousemove', textInputOverlay._dragMove);
        if (textInputOverlay._dragUp) document.removeEventListener('mouseup', textInputOverlay._dragUp);
        if (textInputOverlay._resizeMove) document.removeEventListener('mousemove', textInputOverlay._resizeMove);
        if (textInputOverlay._resizeUp) document.removeEventListener('mouseup', textInputOverlay._resizeUp);
        // Destroy the text color dat.GUI instance
        if (textInputOverlay._textColorGui) { textInputOverlay._textColorGui.destroy(); }
        document.body.removeChild(textInputOverlay);
        textInputOverlay = null;
    }
    pendingTextPos = null;
}

// Text drag handlers (same pattern as image drag)
function textDragStart(ev) {
    this.data = ev.data;
    this.dragging = true;
    this.dragOff = this.data.getLocalPosition(this);
    this.dragOff.x *= this.scale.x;
    this.dragOff.y *= this.scale.y;
}
function textDragEnd() {
    this.dragging = false;
    this.data = null;
    this.dragOff = null;
}
function textDragMove() {
    if (!this.dragging) return;
    var np = this.data.getLocalPosition(this.parent);
    this.position.set(np.x - this.dragOff.x, np.y - this.dragOff.y);
}

function commitTextToCanvas() {
    if (!placedText) return;
    saveState();
    app.renderer.render(placedText, { renderTexture: activeRT(), clear: false });
    app.stage.removeChild(placedText);
    placedText.destroy();
    placedText = null;
    updateTextControls();
}

function removeText() {
    if (!placedText) return;
    app.stage.removeChild(placedText);
    placedText.destroy();
    placedText = null;
    updateTextControls();
}

// Show/hide text control buttons
function updateTextControls() {
    var controls = $('textControls');
    var rotControl = $('textRotationControl');
    if (controls) {
        controls.style.display = placedText ? 'flex' : 'none';
    }
    if (rotControl) {
        rotControl.style.display = placedText ? 'block' : 'none';
    }
    // Reset rotation slider when new text is placed
    if (placedText) {
        var rotSlider = $('textRotation');
        var rotVal = $('textRotationVal');
        if (rotSlider) rotSlider.value = 0;
        if (rotVal) rotVal.textContent = '0';
    }
}

// Update text rotation
function updateTextRotation(degrees) {
    if (!placedText) return;
    placedText.rotation = degrees * Math.PI / 180;
}

// Update text properties (for sliders)
function updateTextSize() {
    if (!placedText) return;
    var fontSize = Math.max(12, config.draw_brush_size * 2);
    placedText.style.fontSize = fontSize;
    placedText.style.padding = Math.max(10, fontSize * 0.2);
}

// ══════════════════════════════════════════════════════════════
//  Pointer events  (drawing on canvas)
// ══════════════════════════════════════════════════════════════
function relPos(e) {
    var p = inputSprite.toLocal(e.data.global);
    p.x += stage_width  / 2;
    p.y += stage_height / 2;
    return p;
}

function onDown(e) {
    var pos = relPos(e);

    // Middle-click = eraser (original behaviour)
    var mid = (e.button === 1);
    if (mid && config.tool !== 'Eraser') {
        config.tool = 'Eraser';
        updateBrush();
        updateToolButtons();
    }

    if (config.tool === 'Text') {
        showTextInput(pos.x, pos.y);
        return;
    }

    if (config.tool === 'Brush' || config.tool === 'Eraser') {
        saveState();
        drawing = true;
        lastPosition = pos;
        drawPoint(pos.x, pos.y);           // single dot
    } else if (isShapeTool()) {
        saveState();
        drawing = true;
        shapeStartPos = pos;
    }
}

function onMove(e) {
    if (!drawing) return;
    var pos = relPos(e);
    if (config.tool === 'Brush' || config.tool === 'Eraser') {
        drawPointLine(lastPosition, pos);
        lastPosition = pos;
    } else if (isShapeTool()) {
        previewShape(shapeStartPos, pos);
    }
}

function onUp(e) {
    if (!drawing) return;
    drawing = false;
    if (isShapeTool() && shapeStartPos) {
        commitShape(shapeStartPos, relPos(e));
        shapePreview.clear();
        shapeStartPos = null;
    }
    lastPosition = null;
}

inputSprite.on('mousedown',      onDown);
inputSprite.on('mousemove',      onMove);
inputSprite.on('mouseup',        onUp);
inputSprite.on('mouseupoutside', onUp);
inputSprite.on('touchstart',     onDown);
inputSprite.on('touchmove',      onMove);
inputSprite.on('touchend',       onUp);
inputSprite.on('mouseleave',     onUp);

// ══════════════════════════════════════════════════════════════
//  Shape tools  (Line / Circle / Rectangle)
// ══════════════════════════════════════════════════════════════
function previewShape(s, c) {
    shapePreview.clear();
    var lw  = Math.max(1, config.draw_brush_size / 2);
    var col = getBrushColor();
    if (config.fillShapes) shapePreview.beginFill(col, 0.35);
    shapePreview.lineStyle({ width: lw, color: col, alpha: 0.7, cap: PIXI.LINE_CAP.ROUND, join: PIXI.LINE_JOIN.ROUND });
    drawShapePath(shapePreview, s, c, lw);
    if (config.fillShapes) shapePreview.endFill();
}

function commitShape(s, e) {
    var g   = new PIXI.Graphics();
    var lw  = Math.max(1, config.draw_brush_size / 2);
    var col = getBrushColor();
    if (config.fillShapes) g.beginFill(col);
    g.lineStyle({ width: lw, color: col, cap: PIXI.LINE_CAP.ROUND, join: PIXI.LINE_JOIN.ROUND });
    drawShapePath(g, s, e, lw);
    if (config.fillShapes) g.endFill();
    app.renderer.render(g, { renderTexture: activeRT(), clear: false });
    g.destroy();
}

function drawShapePath(g, s, e, lw) {
    var cornerRadius = Math.max(5, lw * 2);  // Rounded corners based on line width
    switch (config.tool) {
        case 'Line':
            g.moveTo(s.x, s.y);
            g.lineTo(e.x, e.y);
            break;
        case 'Circle':
            g.drawCircle(s.x, s.y, Math.hypot(e.x - s.x, e.y - s.y));
            break;
        case 'Rectangle':
            var rx = Math.min(s.x, e.x);
            var ry = Math.min(s.y, e.y);
            var rw = Math.abs(e.x - s.x);
            var rh = Math.abs(e.y - s.y);
            // Limit corner radius to half the smallest dimension
            var cr = Math.min(cornerRadius, rw / 2, rh / 2);
            g.drawRoundedRect(rx, ry, rw, rh, cr);
            break;
        case 'Bubble':
            // Speech bubble: oval/ellipse with a triangular tail
            var bx = Math.min(s.x, e.x);
            var by = Math.min(s.y, e.y);
            var bw = Math.abs(e.x - s.x);
            var bh = Math.abs(e.y - s.y);
            var tailH = Math.min(bh * 0.25, 35);  // Tail height
            var bodyH = bh - tailH;  // Main bubble body height
            
            // Center of the ellipse
            var cx = bx + bw / 2;
            var cy = by + bodyH / 2;
            
            // Draw bubble body (ellipse)
            g.drawEllipse(cx, cy, bw / 2, bodyH / 2);
            
            // Draw tail (curved triangle pointing down-left)
            var tailW = Math.min(bw * 0.2, 25);
            var tailX = bx + bw * 0.25;  // Tail starts 25% from left
            g.moveTo(tailX, by + bodyH * 0.7);
            g.quadraticCurveTo(tailX - tailW * 0.3, by + bodyH + tailH * 0.5, tailX - tailW * 0.5, by + bodyH + tailH);
            g.quadraticCurveTo(tailX + tailW * 0.5, by + bodyH * 0.9, tailX + tailW, by + bodyH * 0.75);
            break;
        case 'Crosshair': {
            // ✛ crosshair: + shape sized by drag radius
            var cr2 = Math.hypot(e.x - s.x, e.y - s.y);
            g.moveTo(s.x - cr2, s.y); g.lineTo(s.x + cr2, s.y);
            g.moveTo(s.x, s.y - cr2); g.lineTo(s.x, s.y + cr2);
            break;
        }
        case 'Circleplus': {
            // ⊕ circle with crosshair inside
            var cpr = Math.hypot(e.x - s.x, e.y - s.y);
            g.drawCircle(s.x, s.y, cpr);
            g.moveTo(s.x - cpr, s.y); g.lineTo(s.x + cpr, s.y);
            g.moveTo(s.x, s.y - cpr); g.lineTo(s.x, s.y + cpr);
            break;
        }
        case 'Bullseye': {
            // ◎ concentric circles (3 rings)
            var br = Math.hypot(e.x - s.x, e.y - s.y);
            g.drawCircle(s.x, s.y, br);
            g.drawCircle(s.x, s.y, br * 0.6);
            g.drawCircle(s.x, s.y, br * 0.25);
            break;
        }
        case 'CircleCross': {
            // ⊗ circle with X cross inside
            var ccr = Math.hypot(e.x - s.x, e.y - s.y);
            g.drawCircle(s.x, s.y, ccr);
            var d = ccr * Math.SQRT1_2; // 45° offset
            g.moveTo(s.x - d, s.y - d); g.lineTo(s.x + d, s.y + d);
            g.moveTo(s.x + d, s.y - d); g.lineTo(s.x - d, s.y + d);
            break;
        }
    }
}

// ══════════════════════════════════════════════════════════════
//  Undo / Redo
// ══════════════════════════════════════════════════════════════
function cloneCanvas(src) {
    var c   = document.createElement('canvas');
    c.width   = src.width;
    c.height  = src.height;
    c.getContext('2d').drawImage(src, 0, 0);
    return c;
}

var _autoSaveTimer = null;
function autoSave() {
    if (_autoSaveTimer) clearTimeout(_autoSaveTimer);
    _autoSaveTimer = setTimeout(saveDrawing, 1000);
}

function saveState() {
    try {
        var extracted = app.renderer.extract.canvas(activeRT());
        undoStack.push({ layer: activeLayerIndex, canvas: cloneCanvas(extracted) });
        redoStack = [];
        if (undoStack.length > MAX_UNDO) undoStack.shift();
    } catch (e) { console.warn("Undo snapshot failed:", e); }
    autoSave();
}

function restoreLayer(idx, canvas) {
    var tex = PIXI.Texture.from(canvas);
    var s   = new PIXI.Sprite(tex);
    app.renderer.render(s, { renderTexture: layers[idx].renderTexture, clear: true });
}

function undo() {
    if (!undoStack.length) return;
    var entry = undoStack.pop();
    try {
        var cur = cloneCanvas(app.renderer.extract.canvas(layers[entry.layer].renderTexture));
        redoStack.push({ layer: entry.layer, canvas: cur });
    } catch (e) {}
    restoreLayer(entry.layer, entry.canvas);
}

function redo() {
    if (!redoStack.length) return;
    var entry = redoStack.pop();
    try {
        var cur = cloneCanvas(app.renderer.extract.canvas(layers[entry.layer].renderTexture));
        undoStack.push({ layer: entry.layer, canvas: cur });
    } catch (e) {}
    restoreLayer(entry.layer, entry.canvas);
}

// ══════════════════════════════════════════════════════════════
//  Image placement
// ══════════════════════════════════════════════════════════════
function placeImage(src, isFile) {
    config.imageRotation = 0;
    var rotSlider = $('imgRotation');
    var rotVal    = $('imgRotationVal');
    if (rotSlider) rotSlider.value = 0;
    if (rotVal)    rotVal.textContent = '0';

    var texture = isFile ? PIXI.Texture.from("./Images/" + src) : PIXI.Texture.from(src);
    var imgSpr  = new PIXI.Sprite(texture);
    imgSpr.anchor.set(0.5);
    imgSpr.position.set(stage_width / 2, stage_height / 2);
    imgSpr.rotation  = 0;
    imgSpr.alpha     = config.imageOpacity;
    imgSpr.interactive = true;
    imgSpr.cursor      = "move";
    imgSpr.on("pointerdown",      imgDragStart);
    imgSpr.on("pointerup",        imgDragEnd);
    imgSpr.on("pointerupoutside", imgDragEnd);
    imgSpr.on("pointermove",      imgDragMove);

    var applySize = function() {
        var ow = texture.baseTexture.width;
        var oh = texture.baseTexture.height;
        if (ow > 0 && oh > 0) {
            var sf = config.imageSize / Math.max(ow, oh);
            imgSpr.width  = ow * sf;
            imgSpr.height = oh * sf;
        }
    };
    if (texture.baseTexture.valid) applySize();
    else texture.baseTexture.on('loaded', applySize);

    app.stage.addChild(imgSpr);
    placedImages.push(imgSpr);
}

function updatePlacedImageSize(v) {
    placedImages.forEach(function(s) {
        var ow = s.texture.baseTexture.width;
        var oh = s.texture.baseTexture.height;
        if (ow > 0 && oh > 0) {
            var sf = v / Math.max(ow, oh);
            s.width  = ow * sf;
            s.height = oh * sf;
        }
    });
}

function updateImageOpacity(v) {
    if (placedImages.length) placedImages[placedImages.length - 1].alpha = v;
}

function updateImageRotation() {
    if (placedImages.length)
        placedImages[placedImages.length - 1].rotation = config.imageRotation * Math.PI / 180;
}

function paintToCanvas() {
    if (!placedImages.length) return;
    saveState();
    var s = placedImages[placedImages.length - 1];
    s.alpha = config.imageOpacity;
    app.renderer.render(s, { renderTexture: activeRT(), clear: false });
    config.imageRotation = 0;
    var rotSlider = $('imgRotation');
    var rotVal    = $('imgRotationVal');
    if (rotSlider) rotSlider.value = 0;
    if (rotVal)    rotVal.textContent = '0';
    app.stage.removeChild(s);
    placedImages.pop();
}

function removeLastImage() {
    if (!placedImages.length) return;
    app.stage.removeChild(placedImages.pop());
}

// Image drag handlers
function imgDragStart(ev) {
    this.data     = ev.data;
    this.dragging = true;
    this.dragOff  = this.data.getLocalPosition(this);
    this.dragOff.x *= this.scale.x;
    this.dragOff.y *= this.scale.y;
}
function imgDragEnd()  { this.dragging = false; this.data = null; this.dragOff = null; }
function imgDragMove() {
    if (!this.dragging) return;
    var np = this.data.getLocalPosition(this.parent);
    this.position.set(np.x - this.dragOff.x, np.y - this.dragOff.y);
}

// ══════════════════════════════════════════════════════════════
//  Custom image import
// ══════════════════════════════════════════════════════════════
function importImage() {
    var input   = document.createElement('input');
    input.type    = 'file';
    input.accept  = 'image/*';
    input.style.display = 'none';
    document.body.appendChild(input);

    input.onchange = function(ev) {
        var file = ev.target.files[0];
        if (!file) { document.body.removeChild(input); return; }

        var reader = new FileReader();
        reader.onload = function(e) {
            var dataUrl = e.target.result;
            placeImage(dataUrl, false);

            var ctr = $('imageButtonContainer');
            if (ctr) {
                var btn = document.createElement("button");
                btn.className = 'image-select-btn';
                btn.innerText = "\u{1F4CE} " + file.name;
                btn.onclick = function() { removeLastImage(); placeImage(dataUrl, false); };
                ctr.appendChild(btn);
            }
        };
        reader.readAsDataURL(file);
        document.body.removeChild(input);
    };
    input.click();
}

// ══════════════════════════════════════════════════════════════
//  Layer controls
// ══════════════════════════════════════════════════════════════
function setLayerVisible(i, v) {
    layers[i].sprite.visible = v;
    layers[i].visible = v;
}

// ══════════════════════════════════════════════════════════════
//  Clear canvas
// ══════════════════════════════════════════════════════════════
function clearLayer() {
    saveState();
    var g = new PIXI.Graphics();
    app.renderer.render(g, { renderTexture: activeRT(), clear: true });
    g.destroy();
}

function clearAll() {
    layers.forEach(function(l, i) {
        try {
            undoStack.push({ layer: i, canvas: cloneCanvas(app.renderer.extract.canvas(l.renderTexture)) });
        } catch (e) {}
        var g = new PIXI.Graphics();
        app.renderer.render(g, { renderTexture: l.renderTexture, clear: true });
        g.destroy();
    });
    redoStack = [];
    if (undoStack.length > MAX_UNDO) undoStack = undoStack.slice(-MAX_UNDO);

    placedImages.forEach(function(img) { app.stage.removeChild(img); });
    placedImages = [];
    autoSave();
}

// ══════════════════════════════════════════════════════════════
//  Save / Load  (localStorage)
// ══════════════════════════════════════════════════════════════
function saveDrawing() {
    try {
        var data = {};
        layers.forEach(function(l, i) {
            data['l' + i] = app.renderer.extract.canvas(l.renderTexture).toDataURL('image/png');
        });
        localStorage.setItem('f4e_grease_pencil', JSON.stringify(data));
        console.log("Grease Pencil: drawing saved.");
    } catch (e) { console.error("Save failed:", e); }
}

function loadDrawing() {
    try {
        var raw = localStorage.getItem('f4e_grease_pencil');
        if (!raw) return;
        var data = JSON.parse(raw);
        layers.forEach(function(l, i) {
            var src = data['l' + i];
            if (!src) return;
            var img = new Image();
            img.onload = function() {
                var tex = PIXI.Texture.from(img);
                var s   = new PIXI.Sprite(tex);
                app.renderer.render(s, { renderTexture: l.renderTexture, clear: true });
            };
            img.src = src;
        });
        console.log("Grease Pencil: drawing loaded.");
    } catch (e) { console.error("Load failed:", e); }
}

// ══════════════════════════════════════════════════════════════
//  Keyboard shortcuts
// ══════════════════════════════════════════════════════════════
document.addEventListener('keydown', function(e) {
    if (e.ctrlKey && e.key === 'z') { e.preventDefault(); undo(); }
    if (e.ctrlKey && e.key === 'y') { e.preventDefault(); redo(); }
});

// ══════════════════════════════════════════════════════════════
//  HTML Control Bindings
// ══════════════════════════════════════════════════════════════

// ── Collapsible sections (click title to minimize) ────────────
var sectionTitles = document.querySelectorAll('.section-title');
sectionTitles.forEach(function(title) {
    title.addEventListener('click', function() {
        var section = title.parentElement;
        section.classList.toggle('collapsed');
    });
});

// ── Tool buttons ──────────────────────────────────────────────
var allToolBtns = [
    $('btnBrush'), $('btnEraser'), $('btnText')
];

function updateToolButtons() {
    allToolBtns.forEach(function(btn) {
        if (btn) btn.classList.toggle('active', btn.dataset.tool === config.tool);
    });
    // Sync shape dropdown
    var ddToggle = $('shapeDropdownToggle');
    var ddMenu   = $('shapeDropdownMenu');
    if (ddToggle) {
        if (isShapeTool()) {
            ddToggle.classList.add('active');
            // Update toggle label to show selected shape
            var items = ddMenu ? ddMenu.children : [];
            for (var si = 0; si < items.length; si++) {
                if (items[si].dataset.shape === config.tool) {
                    ddToggle.textContent = items[si].textContent;
                    items[si].classList.add('selected');
                } else {
                    items[si].classList.remove('selected');
                }
            }
        } else {
            ddToggle.textContent = 'Shapes \u25BE';
            ddToggle.classList.remove('active');
            if (ddMenu) {
                var items2 = ddMenu.children;
                for (var si2 = 0; si2 < items2.length; si2++) items2[si2].classList.remove('selected');
            }
        }
    }
}

function selectTool(toolName) {
    config.tool = toolName;
    updateBrush();
    updateToolButtons();
}

allToolBtns.forEach(function(btn) {
    if (btn) btn.addEventListener('click', function() { selectTool(btn.dataset.tool); });
});

// Shape dropdown (custom div-based for DCS browser compatibility)
(function() {
    var toggle = $('shapeDropdownToggle');
    var menu   = $('shapeDropdownMenu');
    if (!toggle || !menu) return;

    toggle.addEventListener('click', function(e) {
        e.stopPropagation();
        var open = menu.style.display !== 'none';
        menu.style.display = open ? 'none' : 'block';
    });

    var items = menu.querySelectorAll('.shape-dropdown-item');
    for (var i = 0; i < items.length; i++) {
        (function(item) {
            item.addEventListener('click', function(e) {
                e.stopPropagation();
                menu.style.display = 'none';
                selectTool(item.dataset.shape);
            });
        })(items[i]);
    }

    // Close menu when clicking elsewhere
    document.addEventListener('click', function() {
        menu.style.display = 'none';
    });
})();

// ── dat.GUI Color Picker (works in embedded game browser) ─────────
var colorGui = new dat.GUI({ autoPlace: false });
var colorController = colorGui.addColor(config, 'brushColor').name('Color');
colorController.onChange(function(value) {
    config.brushColor = value;
    updateBrush();
});

// Place the dat.GUI in our panel
var datGuiContainer = $('datGuiColorContainer');
if (datGuiContainer) {
    datGuiContainer.appendChild(colorGui.domElement);
}

// ── Brush / Eraser size sliders ───────────────────────────────
var brushSizeSlider = $('brushSize');
var brushSizeVal    = $('brushSizeVal');
if (brushSizeSlider) {
    brushSizeSlider.value = config.draw_brush_size;
    if (brushSizeVal) brushSizeVal.textContent = config.draw_brush_size;
    brushSizeSlider.addEventListener('input', function(e) {
        config.draw_brush_size = parseInt(e.target.value);
        if (brushSizeVal) brushSizeVal.textContent = e.target.value;
        updateBrush();
        updateTextSize();  // Update placed text size in real-time
    });
}

var eraserSizeSlider = $('eraserSize');
var eraserSizeVal    = $('eraserSizeVal');
if (eraserSizeSlider) {
    eraserSizeSlider.value = config.erase_brush_size;
    if (eraserSizeVal) eraserSizeVal.textContent = config.erase_brush_size;
    eraserSizeSlider.addEventListener('input', function(e) {
        config.erase_brush_size = parseInt(e.target.value);
        if (eraserSizeVal) eraserSizeVal.textContent = e.target.value;
        updateBrush();
    });
}

// ── Fill shapes checkbox ──────────────────────────────────────
var fillShapesCb = $('fillShapes');
if (fillShapesCb) fillShapesCb.addEventListener('change', function(e) { config.fillShapes = e.target.checked; });

// ── Layer controls (button-based) ─────────────────────────────
var btnLayer1 = $('btnLayer1');
var btnLayer2 = $('btnLayer2');

function updateLayerButtons() {
    if (btnLayer1) btnLayer1.classList.toggle('active', activeLayerIndex === 0);
    if (btnLayer2) btnLayer2.classList.toggle('active', activeLayerIndex === 1);
}

if (btnLayer1) {
    btnLayer1.addEventListener('click', function() {
        activeLayerIndex = 0;
        updateLayerButtons();
    });
}
if (btnLayer2) {
    btnLayer2.addEventListener('click', function() {
        activeLayerIndex = 1;
        updateLayerButtons();
    });
}

// Layer visibility toggle buttons
var btnToggleL1 = $('btnToggleL1');
var btnToggleL2 = $('btnToggleL2');
var layer1Visible = true;
var layer2Visible = true;

function updateVisibilityButtons() {
    if (btnToggleL1) {
        btnToggleL1.textContent = layer1Visible ? 'L1 Visible' : 'L1 Hidden';
        btnToggleL1.classList.toggle('active', layer1Visible);
    }
    if (btnToggleL2) {
        btnToggleL2.textContent = layer2Visible ? 'L2 Visible' : 'L2 Hidden';
        btnToggleL2.classList.toggle('active', layer2Visible);
    }
}

if (btnToggleL1) {
    btnToggleL1.addEventListener('click', function() {
        layer1Visible = !layer1Visible;
        setLayerVisible(0, layer1Visible);
        updateVisibilityButtons();
    });
}
if (btnToggleL2) {
    btnToggleL2.addEventListener('click', function() {
        layer2Visible = !layer2Visible;
        setLayerVisible(1, layer2Visible);
        updateVisibilityButtons();
    });
}
updateVisibilityButtons();

// ── Action buttons ────────────────────────────────────────────
var btnUndo       = $('btnUndo');
var btnRedo       = $('btnRedo');
var btnClearLayer = $('btnClearLayer');
var btnClearAll   = $('btnClearAll');
if (btnUndo)       btnUndo.addEventListener('click', undo);
if (btnRedo)       btnRedo.addEventListener('click', redo);
if (btnClearLayer) btnClearLayer.addEventListener('click', clearLayer);
if (btnClearAll)   btnClearAll.addEventListener('click', clearAll);

// ── Text tool buttons ─────────────────────────────────────────
var btnCommitText = $('btnCommitText');
var btnCancelText = $('btnCancelText');
if (btnCommitText) btnCommitText.addEventListener('click', commitTextToCanvas);
if (btnCancelText) btnCancelText.addEventListener('click', removeText);

// ── Text rotation slider ──────────────────────────────────────
var textRotSlider = $('textRotation');
var textRotVal = $('textRotationVal');
if (textRotSlider) textRotSlider.addEventListener('input', function(e) {
    var deg = parseInt(e.target.value);
    if (textRotVal) textRotVal.textContent = deg;
    updateTextRotation(deg);
});

// ── Image placement sliders ───────────────────────────────────
var imgSizeSlider = $('imgSize');
var imgSizeVal    = $('imgSizeVal');
if (imgSizeSlider) imgSizeSlider.addEventListener('input', function(e) {
    config.imageSize = parseInt(e.target.value);
    if (imgSizeVal) imgSizeVal.textContent = e.target.value;
    updatePlacedImageSize(config.imageSize);
});

var imgOpacitySlider = $('imgOpacity');
var imgOpacityVal    = $('imgOpacityVal');
if (imgOpacitySlider) imgOpacitySlider.addEventListener('input', function(e) {
    config.imageOpacity = parseFloat(e.target.value);
    if (imgOpacityVal) imgOpacityVal.textContent = parseFloat(e.target.value).toFixed(2);
    updateImageOpacity(config.imageOpacity);
});

var imgRotSlider = $('imgRotation');
var imgRotVal    = $('imgRotationVal');
if (imgRotSlider) imgRotSlider.addEventListener('input', function(e) {
    config.imageRotation = parseInt(e.target.value);
    if (imgRotVal) imgRotVal.textContent = e.target.value;
    updateImageRotation();
});

var btnPaint  = $('btnPaintToCanvas');
var btnImport = $('btnImportImage');
if (btnPaint)  btnPaint.addEventListener('click', paintToCanvas);
if (btnImport) btnImport.addEventListener('click', importImage);

// ── Prevent control-panel clicks from bleeding to canvas ─────
var controlPanel = $('controlPanel');
if (controlPanel) {
    controlPanel.addEventListener('pointerdown', function(e) { e.stopPropagation(); });
    controlPanel.addEventListener('mousedown',   function(e) { e.stopPropagation(); });
    controlPanel.addEventListener('touchstart',  function(e) { e.stopPropagation(); });
}

// ══════════════════════════════════════════════════════════════
//  Image-selection buttons  (from Images.json)
// ══════════════════════════════════════════════════════════════
function buildImageButtons(images) {
    var container = $('imageButtonContainer');
    if (!container) return;
    container.innerHTML = '';

    images.forEach(function(img) {
        var btn = document.createElement('button');
        btn.className = 'image-select-btn';
        // Display a cleaner name
        var displayName = img.split('/').pop();
        if (displayName.length > 20) {
            displayName = displayName.substring(0, 17) + '...';
        }
        btn.textContent = displayName;
        btn.addEventListener('click', function() {
            removeLastImage();
            placeImage(img, true);
        });
        container.appendChild(btn);
    });
}

// Remove Image button
var btnRemoveImage = $('btnRemoveImage');
if (btnRemoveImage) {
    btnRemoveImage.addEventListener('click', function() {
        removeLastImage();
    });
}

// Load images using XMLHttpRequest
function loadImagesJson() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', './Images/Images.json', true);
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200 || xhr.status === 0) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    availableImages = data.images;
                    buildImageButtons(availableImages);
                } catch (e) {
                    console.error("Failed to parse images JSON:", e);
                }
            } else {
                console.error("Failed to load images JSON, status:", xhr.status);
            }
        }
    };
    xhr.send();
}
loadImagesJson();

// Auto-load previous drawing on startup
setTimeout(loadDrawing, 500);
