pragma Singleton
import QtQuick
QtObject {
    function createFeature(layer, geometry) {
        var attrs = []
        for (var i = 0; i < layer.fields.names.length; i++) attrs.push(null)
        return {
            id: -1, geometry: geometry, attrs: attrs,
            setAttribute: function(i, v) { this.attrs[i] = v },
            attribute: function(name) { return this.attrs[layer.fields.names.indexOf(name)] }
        }
    }
}
