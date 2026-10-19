pragma Singleton
import QtQuick
// EPSG:2157 is faked as lon/lat × 100000 so reprojection is visible in tests;
// EPSG:29903 / 27700 are rough linear stand-ins that put Dublin in the right grid squares
QtObject {
    function point(x, y) { return { x: x, y: y } }
    function reprojectPoint(pt, src, dst) {
        if (src && src.authid === "EPSG:2157" && (!dst || dst.authid !== "EPSG:2157"))
            return { x: pt.x / 100000, y: pt.y / 100000 }
        if (dst && dst.authid === "EPSG:2157") return { x: pt.x * 100000, y: pt.y * 100000 }
        if (dst && dst.authid === "EPSG:29903") return { x: (pt.x + 10) * 85000, y: (pt.y - 51.25) * 111000 }
        if (dst && dst.authid === "EPSG:27700") return { x: (pt.x + 10) * 40000, y: (pt.y - 49) * 111000 }
        return { x: pt.x, y: pt.y }
    }
    function createGeometryFromWkt(wkt) { return { wkt: wkt, asWkt: function(precision) { return wkt } } }
}
