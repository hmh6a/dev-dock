import Foundation

/// Recognizes ports commonly used while developing so the Ports tab can surface
/// them first, each tagged with the service it usually belongs to.
public enum DevPortCatalog {

    /// Well-known development / service ports → a short human label.
    public static let known: [Int: String] = [
        // Web dev servers
        3000: "Node / React",
        3001: "Node",
        4000: "Dev server",
        4200: "Angular",
        4321: "Astro",
        5000: "Flask / Dev",
        5173: "Vite",
        5174: "Vite",
        8000: "Django / HTTP",
        8080: "HTTP (alt)",
        8081: "Metro / Dev",
        8443: "HTTPS (alt)",
        8888: "Jupyter",
        9000: "Dev server",
        // Mobile / RN / Expo
        19000: "Expo",
        19006: "Expo Web",
        // Databases & stores
        5432: "PostgreSQL",
        5433: "PostgreSQL",
        3306: "MySQL / MariaDB",
        1433: "SQL Server",
        6379: "Redis",
        27017: "MongoDB",
        9200: "Elasticsearch",
        11211: "Memcached",
        // Queues / infra
        5672: "RabbitMQ",
        15672: "RabbitMQ UI",
        // Misc common dev
        3333: "Dev server",
        7000: "Dev server",
        9090: "Prometheus",
        3100: "Grafana / Loki",
    ]

    /// A short service label for a port, if it's a recognized dev port.
    public static func label(for port: Int) -> String? {
        known[port]
    }

    /// Whether a port is a recognized development port.
    public static func isDevPort(_ port: Int) -> Bool {
        known[port] != nil
    }
}

public extension PortEntry {
    /// A friendly service name (e.g. "Vite", "PostgreSQL") when this is a
    /// recognized development port, otherwise `nil`.
    var serviceLabel: String? {
        DevPortCatalog.label(for: port)
    }

    /// Whether this port is one a developer typically uses while working.
    var isDevPort: Bool {
        DevPortCatalog.isDevPort(port)
    }
}
