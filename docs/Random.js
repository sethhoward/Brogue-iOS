var RNGState = new Array(2);
RNGState[0] = new ranctx(0, 0, 0, 0);
RNGState[1] = new ranctx(0, 0, 0, 0);

// Math stuff

function min(x, y) {
	return (((x) < (y)) ? (x) : (y));
}

function max(x, y){	
	return (((x) > (y)) ? (x) : (y))
}
//clamp(x, low, hi)	(min(hi, max(x, low))) 

function clamp(x, low, hi){
    return (min(hi, max(x, low)));
}

// Random

function rot(x, k) {
	return (((x)<<(k))|((x)>>>(32-(k)))) >>> 0;
};

function ranctx(a, b, c, d) {
	this.a = a;
	this.b = b;
	this.c = c;
	this.d = d;
};

function ranval(x) {
    var e = x.a - rot(x.b, 27);
    x.a = x.b ^ rot(x.c, 17);
    x.b = x.c + x.d;
    x.c = x.d + e;
    x.d = e + x.a;
    return x.d;
}

function range(n, RNG) {
	var div;
	var r;
	
	div = (4294967295)/n;
	//div = (2147483647)/n;
	
	do {
		//r = ranval(&(RNGState[RNG])) / div;
		r = Math.abs(ranval((RNGState[RNG])) / div);
	} while (r >= n);
	
	return r;
}
 

function rand_range(lowerBound, upperBound) {
	if (upperBound <= lowerBound) {
		return lowerBound;
	}

	//return lowerBound + range(upperBound-lowerBound+1, rogue.RNG);
	return Math.floor(lowerBound + range(upperBound-lowerBound+1, 0));
}

// seeds with the time if called with a parameter of 0; returns the seed regardless.
// All RNGs are seeded simultaneously and identically.
function seedRandomGenerator(seed) {
	if (seed == 0) {
		var time = new Date().getTime();
		seed = time - 1352700000;
	}
	raninit((RNGState[RNG_SUBSTANTIVE]), seed);
	raninit((RNGState[RNG_COSMETIC]), seed);
	return seed;
}

function raninit(x, seed) {
    var i;
    x.a = 0xf1ea5eed;
 //	x.a = 255;
    x.b = x.c = x.d = seed;
    for (i=0; i<20; ++i) {
        ranval(x);
    }
}