pragma Singleton
import QtQuick
// EPSG:2157 is faked as lon/lat × 100000 so reprojection is visible in tests
QtObject {
    function point(x, y) { return { x: x, y: y } }
    function reprojectPoint(pt, src, dst) {
        if (dst && dst.authid === "EPSG:2157") return { x: pt.x * 100000, y: pt.y * 100000 }
        return { x: pt.x, y: pt.y }
    }
    function createGeometryFromWkt(wkt) { return { wkt: wkt } }
}
