package pgo.trans.passes.scope;

import pgo.errors.IssueContext;
import pgo.model.mpcal.*;
import pgo.model.pcal.PlusCalProcedure;
import pgo.model.pcal.PlusCalStatement;
import pgo.model.pcal.PlusCalVariableDeclaration;
import pgo.model.tla.*;
import pgo.modules.TLAModuleLoader;
import pgo.scope.ChainMap;
import pgo.scope.UID;
import pgo.trans.intermediate.*;
import pgo.trans.passes.expansion.*;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;

public class ScopingPass {
	private ScopingPass() {}

	public static DefinitionRegistry perform(IssueContext ctx, TLAModuleLoader loader,
	                                         Map<String,TLAExpression> constantDefinitions, TLAModule module,
	                                         ModularPlusCalBlock modularPlusCalBlock) {
		DefinitionRegistry registry = new DefinitionRegistry();
		TLAScopeBuilder tlaScope = new TLAScopeBuilder(ctx, registry.getReferences());

		TLAUnitScopingVisitor.scopeModule(module, ctx, tlaScope, registry, loader, new HashSet<>());

		// resolve user-provided constant values from the config file
		for (UID id : registry.getConstants()) {
			String name = registry.getConstantName(id);
			if (!constantDefinitions.containsKey(name)) {
				ctx.error(new ConstantWithNoValueIssue(name, id));
			} else {
				TLAExpression value = constantDefinitions.get(name);
				value.accept(new TLAExpressionScopingVisitor(tlaScope, registry, loader, new HashSet<>()));
				registry.setConstantValue(id, value);
			}
		}

		TLAScopeBuilder modularPlusCalScope = tlaScope.makeNestedScope();

		for (PlusCalVariableDeclaration variableDeclaration : modularPlusCalBlock.getVariables()) {
			modularPlusCalScope.declare(variableDeclaration.getName().getValue(), variableDeclaration.getUID());
			registry.addGlobalVariable(variableDeclaration.getUID());
			variableDeclaration.getValue().accept(new TLAExpressionScopingVisitor(
					tlaScope, registry, loader, new HashSet<>()));
		}

		for (TLAUnit unit : modularPlusCalBlock.getUnits()) {
			unit.accept(new TLAUnitScopingVisitor(ctx, modularPlusCalScope, registry, loader, new HashSet<>()));
		}

		Map<String, ModularPlusCalArchetype> archetypes = new HashMap<>();
		for (ModularPlusCalArchetype archetype : modularPlusCalBlock.getArchetypes()) {
			if (archetypes.containsKey(archetype.getName())) {
				ctx.error(new ArchetypeNameConflictIssue(archetypes.get(archetype.getName()), archetype));
			}
			archetypes.put(archetype.getName(), archetype);

			modularPlusCalScope.defineGlobal(archetype.getName(), archetype.getUID());

			TLAScopeBuilder argScope = new TLAScopeBuilder(
					ctx, new ChainMap<>(tlaScope.getDeclarations()), tlaScope.getDefinitions(),
					tlaScope.getReferences());
			Map<String, UID> args = new ChainMap<>(tlaScope.getDeclarations());

			Stream.concat(archetype.getArguments().stream(), archetype.getVariables().stream())
					.forEach(variableDeclaration -> {
						variableDeclaration.getValue().accept(new TLAExpressionScopingVisitor(
								tlaScope, registry, loader, new HashSet<>()));
						registry.addLocalVariable(variableDeclaration.getUID());
						if (argScope.declare(variableDeclaration.getName().getValue(), variableDeclaration.getUID())) {
							args.put(variableDeclaration.getName().getValue(), variableDeclaration.getUID());
						}
					});

			TLAScopeBuilder archetypeScope = new TLAScopeBuilder(
					ctx, args, new ChainMap<>(tlaScope.getDefinitions()), tlaScope.getReferences());
			archetypeScope.defineLocal("self", archetype.getSelfVariableUID());
			registry.addLocalVariable(archetype.getSelfVariableUID());

			for (PlusCalStatement stmts : archetype.getBody()) {
				stmts.accept(new PlusCalStatementLabelCaptureVisitor(ctx, archetypeScope));
			}

			for (PlusCalStatement stmts : archetype.getBody()) {
				stmts.accept(new PlusCalStatementScopingVisitor(
						ctx, archetypeScope, registry, loader, new HashSet<>()));
			}
		}

		Map<String, ModularPlusCalMappingMacro> mappingMacros = new HashMap<>();
		for (ModularPlusCalMappingMacro mappingMacro : modularPlusCalBlock.getMappingMacros()) {
			if (mappingMacros.containsKey(mappingMacro.getName())) {
				ctx.error(new MappingMacroNameConflictIssue(mappingMacros.get(mappingMacro.getName()), mappingMacro));
			}
			mappingMacros.put(mappingMacro.getName(), mappingMacro);
			modularPlusCalScope.defineGlobal(mappingMacro.getName(), mappingMacro.getUID());

			Map<String, UID> readArgs = new ChainMap<>(tlaScope.getDeclarations());
			readArgs.put("$variable", mappingMacro.getUID());
			TLAScopeBuilder readBodyScope = new TLAScopeBuilder(ctx, readArgs,
					new ChainMap<>(tlaScope.getDefinitions()), tlaScope.getReferences());

			for (PlusCalStatement statement : mappingMacro.getReadBody()) {
				// TODO make this work with qualified macro name
				statement.accept(new PlusCalStatementScopingVisitor(
						ctx,
						readBodyScope,
						registry,
						loader,
						new HashSet<>(),
						(builder, reg, ldr, moduleRecursionSet) -> new MappingMacroTLAExpressionScopingVisitor(
								builder, reg, ldr, moduleRecursionSet, new QualifiedName(mappingMacro.getName()))));
			}

			Map<String, UID> writeArgs = new ChainMap<>(tlaScope.getDeclarations());
			writeArgs.put("$variable", mappingMacro.getUID());
			writeArgs.put("$value", mappingMacro.getSpecialVariableValueUID());
			TLAScopeBuilder writeBodyScope = new TLAScopeBuilder(ctx, writeArgs,
					new ChainMap<>(tlaScope.getDefinitions()), tlaScope.getReferences());

			for (PlusCalStatement statement : mappingMacro.getWriteBody()) {
				// TODO make this work with qualified macro name
				statement.accept(new PlusCalStatementScopingVisitor(
						ctx,
						writeBodyScope,
						registry,
						loader,
						new HashSet<>(),
						(builder, reg, ldr, moduleRecursionSet) -> new MappingMacroTLAExpressionScopingVisitor(
								builder, reg, ldr, moduleRecursionSet, new QualifiedName(mappingMacro.getName()))));
			}
		}

		// instances need access to global variables
		for (ModularPlusCalInstance instance : modularPlusCalBlock.getInstances()) {
			for (ModularPlusCalMapping mapping : instance.getMappings()) {
				modularPlusCalScope.reference(mapping.getTarget().getName(), mapping.getTarget().getUID());
				modularPlusCalScope.reference(mapping.getVariable().getName(), mapping.getVariable().getUID());
			}
			if (!archetypes.containsKey(instance.getTarget())) {
				ctx.error(new UnknownArchetypeTargetIssue(instance));
				continue;
			}
			ModularPlusCalArchetype archetype = archetypes.get(instance.getTarget());
			if (instance.getParams().size() != archetype.getArguments().size()) {
				ctx.error(new InstanceArgumentCountMismatchIssue(instance, archetype));
				continue;
			}
			for (TLAExpression expression : instance.getParams()) {
				expression.accept(new TLAExpressionScopingVisitor(
						modularPlusCalScope, registry, loader, new HashSet<>()));
			}
		}

		modularPlusCalBlock.getProcesses().accept(new PlusCalProcessesScopingVisitor(
				ctx, modularPlusCalScope, tlaScope, registry, loader, new HashSet<>()));

		for (PlusCalProcedure proc : modularPlusCalBlock.getProcedures()) {
			registry.addProcedure(proc);
			modularPlusCalScope.defineGlobal(proc.getName(), proc.getUID());

			TLAScopeBuilder argScope = new TLAScopeBuilder(
					ctx, new ChainMap<>(tlaScope.getDeclarations()), new HashMap<>(),
					modularPlusCalScope.getReferences());
			Map<String, UID> args = new ChainMap<>(tlaScope.getDeclarations());

			for (PlusCalVariableDeclaration arg : proc.getArguments()) {
				arg.getValue().accept(new TLAExpressionScopingVisitor(tlaScope, registry, loader, new HashSet<>()));
				registry.addLocalVariable(arg.getUID());
				if (argScope.declare(arg.getName().getValue(), arg.getUID())) {
					args.put(arg.getName().getValue(), arg.getUID());
				}
			}

			TLAScopeBuilder procScope = new TLAScopeBuilder(
					ctx, args, new ChainMap<>(modularPlusCalScope.getDefinitions()),
					modularPlusCalScope.getReferences());

			for (PlusCalStatement stmts : proc.getBody()) {
				stmts.accept(new PlusCalStatementLabelCaptureVisitor(ctx, procScope));
			}

			for (PlusCalStatement stmts : proc.getBody()) {
				stmts.accept(new PlusCalStatementScopingVisitor(ctx, procScope, registry, loader, new HashSet<>()));
			}
		}

		return registry;
	}
}
