import SwiftData

/// The migration plan for the on-device store; every `DataStack` location passes it.
///
/// To change the schema after a store has shipped: copy the models into a new `SchemaV2`
/// (`Schema.Version(2, 0, 0)`), append it to ``schemas``, add a stage (`.lightweight` for
/// additive changes, `.custom` when data must be transformed), point ``CurrentSchema`` at it,
/// and add a test that migrates a store populated with the previous version.
public enum ABSMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
