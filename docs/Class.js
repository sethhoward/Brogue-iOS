/**
 * Class.js: A class factory.
 */
function Class(members) {
 
    // setup proxy
    var Proxy = function() {};
    Proxy.prototype = (members.base || Class).prototype;
 
    // setup constructor
    members.init = members.init || function() {
        if (Proxy.prototype.hasOwnProperty("init")) {
            Proxy.prototype.init.apply(this, arguments);
        }
    };
    var Shell = members.init;
 
    // setup inheritance
    Shell.prototype = new Proxy();
    Shell.prototype.base = Proxy.prototype;
 
    // setup identity
    Shell.prototype.constructor = Shell;
 
    // setup augmentation
    Shell.grow = function(items) {
        for (var item in items) {
            if (!Shell.prototype.hasOwnProperty(item)) {
                Shell.prototype[item] = items[item];
            }
        }
        return Shell;
    };
 
    // attach members and return the new class
    return Shell.grow(members);
}