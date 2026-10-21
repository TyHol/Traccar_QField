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
    // Only the time filters auto-save uses: "fix_time" >= to_datetime('…') [AND "fix_time" < to_datetime('…')]
    function createFeatureIteratorFromExpression(layer, expr) {
        layer._exprReads = (layer._exprReads || []).concat([expr])
        var lo = /"fix_time" >= to_datetime\('([^']+)'\)/.exec(expr), hi = /"fix_time" < to_datetime\('([^']+)'\)/.exec(expr)
        var a = lo ? new Date(lo[1]).getTime() : -Infinity, b = hi ? new Date(hi[1]).getTime() : Infinity
        var i = 0, fs = layer._committed.filter(function(f) {
            var t = new Date(String(f.attribute("fix_time"))).getTime()
            return t >= a && t < b
        })
        return { hasNext: function() { return i < fs.length },
                 next: function() { return fs[i++] },
                 close: function() {} }
    }
}
