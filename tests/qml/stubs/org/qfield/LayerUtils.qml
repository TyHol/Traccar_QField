pragma Singleton
import QtQuick
QtObject {
    function addFeature(layer, feature) { return layer._add(feature) }
    function fieldType(field) { return field ? field.type : "" }
    function createFeatureIterator(layer) {
        var i = 0, fs = layer._committed.slice()
        return { hasNext: function() { return i < fs.length },
                 next: function() { return fs[i++] },
                 close: function() {} }
    }
}
