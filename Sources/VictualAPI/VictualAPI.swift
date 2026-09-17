/// Generated bindings for the Victual REST API.
///
/// Everything in this module other than this file is produced at build time by
/// swift-openapi-generator from `openapi.json`, which
/// `Scripts/update-openapi.py` derives from the upstream Victual specification.
/// Do not edit the generated document by hand — change the script instead, so
/// the next upstream sync keeps the fix.
///
/// The generator emits the unqualified names `Client`, `Components`,
/// `Operations` and `Servers`. Those are easy to collide with in an app target,
/// so prefer the aliases below when referring to them from outside this module.
public enum VictualAPI {}

/// The generated low-level client. ``VictualCore`` wraps this with
/// authentication, transport configuration and typed errors; reach for it
/// directly when you need an endpoint the wrapper does not surface.
public typealias VictualAPIClient = Client

/// The generated schema types — `VictualAPIComponents.Schemas.Product` and so on.
public typealias VictualAPIComponents = Components

/// The generated per-operation input and output types.
public typealias VictualAPIOperations = Operations

/// The `servers` block of the specification.
public typealias VictualAPIServers = Servers
