pragma Singleton
import QtQuick
QtObject {
    function fromDescription(d) { return { authid: d, isGeographic: d === "EPSG:4326" } }
}
