
var rectArray = new Array2D(kCOLS, kROWS);
var drawContext;
var fontSize = 14;

window.onload = init;
window.onresize = resizeBroswerWindowHandler;

var resizeTimeout;
function resizeBroswerWindowHandler() {
	if (resizeTimeout != undefined) {
		clearTimeout(resizeTimeout);
	};

	resizeTimeout = setTimeout("populateRectInWindow()", 50);
}

function init() {
	populateRectInWindow();
	blackout();

	for(var i = 0; i < kCOLS; i++) {
		for(var j = 0; j < kROWS; j++) {
			displayBuffer.set(i, j, new cellDisplayBuffer());
		}
	}

	document.getElementById("bodyContainer").style.fontSize = fontSize + "px";

	var element = document.getElementById("playArea");
	drawContext = element.getContext('2d');

	titleMenu();
};

function blackout() {
	for (var j = 0; j < kROWS; j++) {
		for (var i = 0; i < kCOLS; i++) {
			var rect = rectArray.get(i, j);
			var color = new Color(0, 0, 0);
			rect.color = color;
		}
	};
}

function draw() {
	var cols = rectArray.width;
	var rows = rectArray.height;

	for(var i = 0; i < cols; i++) {
		for(var j = 0; j < rows; j++) {
			var rect = rectArray.get(i, j);
			if (rect.isDirty) {
				drawContext.fillStyle = rect.color.rgbaStyle();
				drawContext.fillRect(rect.x, rect.y, rect.width, rect.height);
			};
		}
	};
};

function populateRectInWindow() {
	var hPx = 1024.0;
	var vPx = 768.0;

	var size = {
  		width: window.innerWidth || document.body.clientWidth,
  		height: window.innerHeight || document.body.clientHeight
	}

	hPx = size.width;
	vPx = size.height;

	var canvas = document.getElementsByTagName('canvas')[0];
	canvas.width  = hPx;
	canvas.height = vPx;

	for (var j = 0; j < kROWS; j++) {
		for (var i = 0; i < kCOLS; i++) {
			var rect = new Rect(Math.round(hPx * i / kCOLS), Math.round(vPx * j / kROWS), Math.round(hPx * (i + 1) / kCOLS) - Math.round(hPx * i / kCOLS), Math.round(vPx * (j + 1) / kROWS) - Math.round(vPx * j / kROWS));
			var color = new Color(0, 0, 0);
			rect.color = color;
			rect.isDirty = true;
			rectArray.set(i, j, rect);
		}
	};
};


function plotChar(inputChar, xLoc, yLoc, foreRed, foreGreen, foreBlue, backRed, backGreen, backBlue) {
	var color = rectArray.get(xLoc, yLoc).color;
	color.red = Math.floor(backRed/100 * 255);
	color.green = Math.floor(backGreen/100 *255);
	color.blue = Math.floor(backBlue/100*255);
	rectArray.get(xLoc, yLoc).isDirty = true;
}
