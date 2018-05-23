package pgo.trans.intermediate;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import pgo.model.tla.PGoTLABinOp;
import pgo.model.tla.PGoTLABool;
import pgo.model.tla.PGoTLACase;
import pgo.model.tla.PGoTLAExistential;
import pgo.model.tla.PGoTLAExpression;
import pgo.model.tla.PGoTLAExpressionVisitor;
import pgo.model.tla.PGoTLAFunction;
import pgo.model.tla.PGoTLAFunctionCall;
import pgo.model.tla.PGoTLAFunctionSet;
import pgo.model.tla.PGoTLAFunctionSubstitution;
import pgo.model.tla.PGoTLAGeneralIdentifier;
import pgo.model.tla.PGoTLAIdentifier;
import pgo.model.tla.PGoTLAIf;
import pgo.model.tla.PGoTLALet;
import pgo.model.tla.PGoTLAMaybeAction;
import pgo.model.tla.PGoTLANumber;
import pgo.model.tla.PGoTLAOperatorCall;
import pgo.model.tla.PGoTLAQuantifiedExistential;
import pgo.model.tla.PGoTLAQuantifiedUniversal;
import pgo.model.tla.PGoTLAQuantifierBound;
import pgo.model.tla.PGoTLARecordConstructor;
import pgo.model.tla.PGoTLARecordSet;
import pgo.model.tla.PGoTLARequiredAction;
import pgo.model.tla.PGoTLASetComprehension;
import pgo.model.tla.PGoTLASetConstructor;
import pgo.model.tla.PGoTLASetRefinement;
import pgo.model.tla.PGoTLAString;
import pgo.model.tla.PGoTLATuple;
import pgo.model.tla.PGoTLAUnary;
import pgo.model.tla.PGoTLAUnit;
import pgo.model.tla.PGoTLAUniversal;
import pgo.model.tla.PlusCalDefaultInitValue;
import pgo.model.type.*;
import pgo.scope.UID;

public class TLAExpressionTypeConstraintVisitor extends PGoTLAExpressionVisitor<PGoType, RuntimeException> {

	private PGoTypeSolver solver;
	private PGoTypeGenerator generator;
	private Map<UID, PGoTypeVariable> mapping;
	private DefinitionRegistry registry;

	public TLAExpressionTypeConstraintVisitor(DefinitionRegistry registry, PGoTypeSolver solver, PGoTypeGenerator generator, Map<UID, PGoTypeVariable> mapping) {
		this.registry = registry;
		this.solver = solver;
		this.generator = generator;
		this.mapping = mapping;
	}

	public PGoType wrappedVisit(PGoTLAExpression expr) {
		PGoType result = expr.accept(this);
		if(!mapping.containsKey(expr.getUID())) {
			PGoTypeVariable self = generator.get();
			solver.accept(new PGoTypeConstraint(expr, result, self));
			mapping.put(expr.getUID(), self);
		}
		return result;
	}

	private void processQuantifierBound(PGoTLAQuantifierBound qb) {
		PGoTypeVariable elementType = generator.get();
		solver.accept(new PGoTypeConstraint(qb, new PGoTypeSet(elementType), wrappedVisit(qb.getSet())));
		switch(qb.getType()) {
		case IDS:
			for(PGoTLAIdentifier id : qb.getIds()) {
				PGoTypeVariable idType = generator.get();
				mapping.put(id.getUID(), idType);
				solver.accept(new PGoTypeConstraint(qb, elementType, idType));
			}
			break;
		case TUPLE:
			List<PGoType> tupleTypes = new ArrayList<>();
			for(PGoTLAIdentifier id : qb.getIds()) {
				PGoTypeVariable idType = generator.get();
				mapping.put(id.getUID(), idType);
				tupleTypes.add(idType);
			}
			solver.accept(new PGoTypeConstraint(qb, elementType, new PGoTypeTuple(tupleTypes)));
			break;
		default:
			throw new RuntimeException("unreachable");
		}
	}

	@Override
	public PGoType visit(PGoTLAFunctionCall pGoTLAFunctionCall) throws RuntimeException {
		PGoType fnType = wrappedVisit(pGoTLAFunctionCall.getFunction());
		List<PGoType> paramTypes = new ArrayList<>();
		for(PGoTLAExpression param : pGoTLAFunctionCall.getParams()) {
			paramTypes.add(wrappedVisit(param));
		}
		PGoTypeVariable returnType = generator.get();
		solver.accept(new PGoTypeConstraint(pGoTLAFunctionCall, fnType, new PGoTypeFunction(paramTypes, returnType)));
		return returnType;
	}

	@Override
	public PGoType visit(PGoTLABinOp pGoTLABinOp) throws RuntimeException {
		OperatorAccessor op = registry.findOperator(
				registry.followReference(pGoTLABinOp.getOperation().getUID()));
		return op.constrainTypes(
				pGoTLABinOp.getOperation(),
				registry,
				Arrays.asList(wrappedVisit(pGoTLABinOp.getLHS()), wrappedVisit(pGoTLABinOp.getRHS())),
				solver, generator, mapping);
	}

	@Override
	public PGoType visit(PGoTLABool pGoTLABool) throws RuntimeException {
		return PGoTypeBool.getInstance();
	}

	@Override
	public PGoType visit(PGoTLACase pGoTLACase) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLAExistential pGoTLAExistential) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLAFunction pGoTLAFunction) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLAFunctionSet pGoTLAFunctionSet) throws RuntimeException {
		PGoType from = wrappedVisit(pGoTLAFunctionSet.getFrom());
		PGoType to = wrappedVisit(pGoTLAFunctionSet.getTo());
		solver.accept(new PGoTypeConstraint(pGoTLAFunctionSet, from, new PGoTypeSet(generator.get())));
		solver.accept(new PGoTypeConstraint(pGoTLAFunctionSet, to, new PGoTypeSet(generator.get())));
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLAFunctionSubstitution pGoTLAFunctionSubstitution) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLAIf pGoTLAIf) throws RuntimeException {
		solver.accept(new PGoTypeConstraint(pGoTLAIf, wrappedVisit(pGoTLAIf.getCond()), PGoTypeBool.getInstance()));
		PGoTypeVariable v = generator.get();
		solver.accept(new PGoTypeConstraint(pGoTLAIf, wrappedVisit(pGoTLAIf.getTval()), v));
		solver.accept(new PGoTypeConstraint(pGoTLAIf, wrappedVisit(pGoTLAIf.getFval()), v));
		return v;
	}

	@Override
	public PGoType visit(PGoTLALet pGoTLALet) throws RuntimeException {
		// TODO: let polymorphism
		for(PGoTLAUnit unit : pGoTLALet.getDefinitions()) {
			unit.accept(new TLAUnitTypeConstraintVisitor(registry, solver, generator, mapping));
		}
		return wrappedVisit(pGoTLALet.getBody());
	}

	@Override
	public PGoType visit(PGoTLAGeneralIdentifier pGoTLAVariable) throws RuntimeException {
		UID uid = registry.followReference(pGoTLAVariable.getUID());
		if(mapping.containsKey(uid)){
			return mapping.get(uid);
		}else {
			PGoTypeVariable v = generator.get();
			mapping.put(uid, v);
			return v;
		}
	}

	@Override
	public PGoType visit(PGoTLATuple pGoTLATuple) throws RuntimeException {
		Map<Integer, PGoType> elementTypes = new HashMap<>();
		List<PGoTLAExpression> elements = pGoTLATuple.getElements();
		for(int i = 0; i < elements.size(); ++i) {
			elementTypes.put(i, wrappedVisit(elements.get(i)));
		}
		return new PGoTypeUnrealizedTuple(elementTypes);
	}

	@Override
	public PGoType visit(PGoTLAMaybeAction pGoTLAMaybeAction) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLANumber pGoTLANumber) throws RuntimeException {
		// TODO this check should be more sophisticated
		if (pGoTLANumber.getVal().contains(".")) {
			return PGoTypeDecimal.getInstance();
		}
		return new PGoTypeUnrealizedNumber(PGoTypeInt.getInstance());
	}

	@Override
	public PGoType visit(PGoTLAOperatorCall pGoTLAOperatorCall) throws RuntimeException {
		List<PGoType> arguments = new ArrayList<>();
		for(PGoTLAExpression arg : pGoTLAOperatorCall.getArgs()) {
			arguments.add(wrappedVisit(arg));
		}
		OperatorAccessor op = registry.findOperator(
				registry.followReference(pGoTLAOperatorCall.getName().getUID()));
		return op.constrainTypes(pGoTLAOperatorCall, registry, arguments, solver, generator, mapping);
	}

	@Override
	public PGoType visit(PGoTLAQuantifiedExistential pGoTLAQuantifiedExistential) throws RuntimeException {
		for(PGoTLAQuantifierBound qb : pGoTLAQuantifiedExistential.getIds()) {
			processQuantifierBound(qb);
		}
		wrappedVisit(pGoTLAQuantifiedExistential.getBody());
		return PGoTypeBool.getInstance();
	}

	@Override
	public PGoType visit(PGoTLAQuantifiedUniversal pGoTLAQuantifiedUniversal) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLARecordConstructor pGoTLARecordConstructor) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLARecordSet pGoTLARecordSet) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLARequiredAction pGoTLARequiredAction) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PGoTLASetConstructor pGoTLASetConstructor) throws RuntimeException {
		PGoTypeVariable elementType = generator.get();
		for(PGoTLAExpression element : pGoTLASetConstructor.getContents()) {
			solver.accept(new PGoTypeConstraint(pGoTLASetConstructor, elementType, wrappedVisit(element)));
		}
		return new PGoTypeSet(elementType);
	}

	@Override
	public PGoType visit(PGoTLASetComprehension pGoTLASetComprehension) throws RuntimeException {
		for(PGoTLAQuantifierBound qb : pGoTLASetComprehension.getBounds()) {
			processQuantifierBound(qb);
		}
		PGoType elementType = wrappedVisit(pGoTLASetComprehension.getBody());
		return new PGoTypeSet(elementType);
	}

	@Override
	public PGoType visit(PGoTLASetRefinement pGoTLASetRefinement) throws RuntimeException {
		PGoType from = wrappedVisit(pGoTLASetRefinement.getFrom());
		PGoTypeVariable elementType = generator.get();
		solver.accept(new PGoTypeConstraint(pGoTLASetRefinement, from, new PGoTypeSet(elementType)));
		if(pGoTLASetRefinement.getIdent().isTuple()) {
			List<PGoType> elements = new ArrayList<>();
			for(PGoTLAIdentifier id : pGoTLASetRefinement.getIdent().getTuple()) {
				PGoTypeVariable v = generator.get();
				mapping.put(id.getUID(), v);
				elements.add(v);
			}
			solver.accept(new PGoTypeConstraint(pGoTLASetRefinement, elementType, new PGoTypeTuple(elements)));
		}else {
			PGoTLAIdentifier id = pGoTLASetRefinement.getIdent().getId();
			mapping.put(id.getUID(), elementType);
		}
		PGoType condition = wrappedVisit(pGoTLASetRefinement.getWhen());
		solver.accept(new PGoTypeConstraint(pGoTLASetRefinement, condition, PGoTypeBool.getInstance()));
		return new PGoTypeSet(elementType);
	}

	@Override
	public PGoType visit(PGoTLAString pGoTLAString) throws RuntimeException {
		return PGoTypeString.getInstance();
	}

	@Override
	public PGoType visit(PGoTLAUnary pGoTLAUnary) throws RuntimeException {
		UID ref = registry.followReference(pGoTLAUnary.getOperation().getUID());
		OperatorAccessor op = registry.findOperator(ref);
		List<PGoType> args = Collections.singletonList(wrappedVisit(pGoTLAUnary.getOperand()));
		return op.constrainTypes(pGoTLAUnary.getOperation(), registry, args, solver, generator, mapping);
	}

	@Override
	public PGoType visit(PGoTLAUniversal pGoTLAUniversal) throws RuntimeException {
		throw new RuntimeException("TODO");
	}

	@Override
	public PGoType visit(PlusCalDefaultInitValue plusCalDefaultInitValue) throws RuntimeException {
		PGoTypeVariable v = generator.get();
		mapping.put(plusCalDefaultInitValue.getUID(), v);
		return v;
	}

}
