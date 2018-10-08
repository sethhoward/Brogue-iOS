function Point(x, y) {
	this.x = x;
	this.y = y;

	this.description = function() {
		return "<Point> x: " + this.x + " y: " + this.y;
	}
};

function Rect(x, y, width, height) {
	this.x = x;
	this.y = y;
	this.width = width;
	this.height = height;
	this.color = 0;
	this.isDirty = false;

	
};

Rect.prototype.centerPointToScreen = function() {
	var x = Math.round(this.x + this.width/2) - fontSize/2;
	var y = Math.round(this.y + this.height/2) - fontSize/2 - 2;
	var point = new Point(x, y);

	return point;
};

Rect.prototype.description = function() {
	return ("<Rect>" + "x: " + x + " y: " + y + " width: " + this.width + " height: " + this.height + " color: " + this.color.description());
};