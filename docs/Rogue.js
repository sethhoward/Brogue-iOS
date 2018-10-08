var kROWS = 34;
var kCOLS = 100;
var ROWS = kROWS;
var COLS = kCOLS;

var RNG_SUBSTANTIVE = 0;
var RNG_COSMETIC = 1;

function cellDisplayBuffer() {
	this.character = ' ';
	this.foreColorComponents = [0, 0, 0];
	this.backColorComponents = [0, 0, 0];
	this.opacity = 0;
	this.needsUpdate = false; 
};