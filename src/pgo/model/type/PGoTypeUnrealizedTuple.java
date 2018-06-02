package pgo.model.type;

import java.util.*;

import pgo.errors.Issue;
import pgo.errors.IssueContext;
import pgo.util.Origin;

/**
 * Represents an unrealized tuple.
 */
public class PGoTypeUnrealizedTuple extends PGoType {
	private Map<Integer, PGoType> elementTypes;
	private boolean sizeKnown;
	public enum RealType {
		Unknown, Chan, Set, Slice, Tuple
	}
	private RealType realType;

	public PGoTypeUnrealizedTuple(List<Origin> origins) {
		this(new HashMap<>(), origins);
	}

	public PGoTypeUnrealizedTuple(Map<Integer, PGoType> elementTypes, List<Origin> origins) {
		this(elementTypes, false, origins);
	}

	public PGoTypeUnrealizedTuple(Map<Integer, PGoType> elementTypes, boolean sizeKnown, List<Origin> origins) {
		super(origins);
		this.elementTypes = new HashMap<>(elementTypes);
		this.sizeKnown = sizeKnown;
		this.realType = RealType.Unknown;
	}

	public Map<Integer, PGoType> getElementTypes() {
		return Collections.unmodifiableMap(elementTypes);
	}

	public boolean hasKnownSize() {
		return sizeKnown;
	}

	public RealType getRealType() {
		return realType;
	}

	public boolean isSimpleContainerType() {
		return realType == RealType.Chan || realType == RealType.Set || realType == RealType.Slice;
	}

	public int getProbableSize() {
		return elementTypes.keySet().stream().max(Comparator.naturalOrder()).orElse(-1) + 1;
	}

	public Optional<Issue> harmonize(PGoTypeSolver solver, PGoTypeConstraint constraint, PGoSimpleContainerType other) {
		if (realType != RealType.Unknown && realType != other.getRealType()) {
			return Optional.of(new UnsatisfiableConstraintIssue(constraint, this, other));
		}
		PGoType elemType = other.getElementType();
		elementTypes.forEach((k, v) -> solver.addConstraint(new PGoTypeMonomorphicConstraint(this, elemType, v)));
		Optional<Issue> issue = solver.unify();
		if (issue.isPresent()) {
			return issue;
		}
		// from this point onward, type unification was successful
		sizeKnown = true;
		if (other instanceof PGoTypeChan) {
			realType = RealType.Chan;
		} else if (other instanceof PGoTypeSet) {
			realType = RealType.Set;
		} else if (other instanceof PGoTypeSlice) {
			realType = RealType.Slice;
		} else {
			throw new RuntimeException("unreachable");
		}
		// we have to link the element types here again because this constraint may be the only link between the element
		// type and the rest of the types
		elementTypes.forEach((k, v) -> solver.addConstraint(new PGoTypeMonomorphicConstraint(this, elemType, v)));
		// once the link has been made, we can safely throw away what's in elementTypes
		elementTypes.clear();
		elementTypes.put(0, elemType);
		return Optional.empty();
	}

	public Optional<Issue> harmonize(PGoTypeConstraint constraint, PGoTypeSolver solver, PGoTypeTuple other) {
		if (isSimpleContainerType()) {
			return Optional.of(new UnsatisfiableConstraintIssue(constraint, this, other));
		}
		List<PGoType> elemTypes = other.getElementTypes();
		int probableSize = getProbableSize();
		if (probableSize > elemTypes.size() || (sizeKnown && probableSize < elemTypes.size())) {
			return Optional.of(new UnsatisfiableConstraintIssue(constraint, this, other));
		}
		elementTypes.forEach((k, v) -> solver.addConstraint(new PGoTypeMonomorphicConstraint(this, elemTypes.get(k), v)));
		Optional<Issue> issue = solver.unify();
		if (issue.isPresent()) {
			return issue;
		}
		// from this point onward, type unification was successful
		sizeKnown = true;
		realType = RealType.Tuple;
		for (int i = 0; i < elemTypes.size(); i++) {
			if (elementTypes.containsKey(i)) {
				solver.addConstraint(new PGoTypeMonomorphicConstraint(this, elementTypes.get(i), elemTypes.get(i)));
			} else {
				elementTypes.put(i, elemTypes.get(i));
			}
		}
		return Optional.empty();
	}

	public Optional<Issue> harmonize(PGoTypeConstraint constraint, PGoTypeSolver solver, PGoTypeUnrealizedTuple other) {
		if (sizeKnown && other.sizeKnown && getProbableSize() != other.getProbableSize()) {
			return Optional.of(new UnsatisfiableConstraintIssue(constraint, this, other));
		}
		if (realType != RealType.Unknown && other.realType != RealType.Unknown && realType != other.realType) {
			return Optional.of(new UnsatisfiableConstraintIssue(constraint, this, other));
		}
		boolean isSizeKnown = sizeKnown || other.sizeKnown;
		int probableSize = Integer.max(getProbableSize(), other.getProbableSize());
		for (int i = 0; i < probableSize; i++) {
			if (elementTypes.containsKey(i) && other.elementTypes.containsKey(i)) {
				solver.addConstraint(new PGoTypeMonomorphicConstraint(this, elementTypes.get(i), other.elementTypes.get(i)));
			}
		}
		Optional<Issue> issue = solver.unify();
		if (issue.isPresent()) {
			return issue;
		}
		// from this point onward, type unification was successful
		sizeKnown = isSizeKnown;
		other.sizeKnown = isSizeKnown;
		if (realType == RealType.Unknown) {
			realType = other.realType;
		}
		if (other.realType == RealType.Unknown) {
			other.realType = realType;
		}
		if (isSimpleContainerType() && other.isSimpleContainerType()) {
			List<PGoType> ts = new ArrayList<>(elementTypes.values());
			ts.addAll(other.elementTypes.values());
			// collect constraints if ts.size() > 0
			if (ts.size() > 0) {
				PGoType first = ts.get(0);
				for (PGoType t : ts.subList(1, ts.size())) {
					solver.addConstraint(new PGoTypeMonomorphicConstraint(this, first, t));
				}
				HashMap<Integer, PGoType> m = new HashMap<>(Collections.singletonMap(0, ts.get(0)));
				elementTypes = m;
				other.elementTypes = m;
				return Optional.empty();
			}
		}
		HashMap<Integer, PGoType> m = new HashMap<>();
		for (int i = 0; i < probableSize; i++) {
			if (elementTypes.containsKey(i) && other.elementTypes.containsKey(i)) {
				solver.addConstraint(new PGoTypeMonomorphicConstraint(this, elementTypes.get(i), other.elementTypes.get(i)));
			}
			if (elementTypes.containsKey(i)) {
				m.put(i, elementTypes.get(i));
			} else if (other.elementTypes.containsKey(i)) {
				m.put(i, other.elementTypes.get(i));
			}
		}
		elementTypes = m;
		other.elementTypes = m;
		return Optional.empty();
	}

	@Override
	public boolean equals(Object obj) {
		if (!(obj instanceof PGoTypeUnrealizedTuple)) {
			return false;
		}
		PGoTypeUnrealizedTuple other = (PGoTypeUnrealizedTuple) obj;
		return sizeKnown == other.sizeKnown && elementTypes.equals(other.elementTypes);
	}

	@Override
	public boolean contains(PGoTypeVariable v) {
		return elementTypes.values().stream().anyMatch(t -> t.contains(v));
	}

	@Override
	public boolean containsVariables() {
		return !sizeKnown || elementTypes.values().stream().anyMatch(PGoType::containsVariables);
	}

	@Override
	public void collectVariables(Set<PGoTypeVariable> vars) {
		elementTypes.values().forEach(t -> t.collectVariables(vars));
	}

	@Override
	public PGoType substitute(Map<PGoTypeVariable, PGoType> mapping) {
		for (int i : elementTypes.keySet()) {
			elementTypes.put(i, elementTypes.get(i).substitute((mapping)));
		}
		return this;
	}

	@Override
	public PGoType realize(IssueContext ctx) {
		if (!sizeKnown || realType == RealType.Unknown ||
				(getProbableSize() != 1 && realType != RealType.Tuple)) {
			ctx.error(new UnrealizableTypeIssue(this));
			return this;
		}
		if (realType == RealType.Tuple) {
			List<PGoType> sub = new ArrayList<>();
			for (int i = 0; i < getProbableSize(); i++) {
				if (!elementTypes.containsKey(i)) {
					ctx.error(new UnrealizableTypeIssue(this));
					return this;
				}
				sub.add(elementTypes.get(i).realize(ctx));
			}
			return new PGoTypeTuple(sub, getOrigins());
		}
		PGoType elemType = elementTypes.get(0);
		switch (realType) {
			case Chan:
				return new PGoTypeChan(elemType, getOrigins());
			case Set:
				return new PGoTypeSet(elemType, getOrigins());
			case Slice:
				return new PGoTypeSlice(elemType, getOrigins());
			case Tuple:
			case Unknown:
			default:
				throw new RuntimeException("unreachable");
		}
	}

	@Override
	public String toTypeName() {
		StringBuilder s = new StringBuilder();
		s.append("UnrealizedTuple");
		switch (realType) {
			case Chan:
				s.append("<").append("Chan").append(">");
				break;
			case Set:
				s.append("<").append("Set").append(">");
				break;
			case Slice:
				s.append("<").append("Slice").append(">");
				break;
			case Tuple:
				s.append("<").append("Tuple").append(">");
				break;
			case Unknown:
			default:
				// nothing
		}
		s.append("[");
		int probableSize = getProbableSize();
		for (int i = 0; i < probableSize; i++) {
			if (elementTypes.containsKey(i)) {
				s.append(elementTypes.get(i).toTypeName());
			} else {
				s.append("?");
			}
			if (i != probableSize - 1) {
				s.append(", ");
			}
		}
		if (!sizeKnown && probableSize > 0) {
			s.append(", ...?");
		}
		if (!sizeKnown && probableSize == 0) {
			s.append("...?");
		}
		s.append("]");
		return s.toString();
	}

	@Override
	public PGoType copy() {
		PGoTypeUnrealizedTuple copy = new PGoTypeUnrealizedTuple(getOrigins());
		elementTypes.forEach((k, v) -> copy.elementTypes.put(k, v.copy()));
		copy.sizeKnown = sizeKnown;
		copy.realType = realType;
		return copy;
	}

	@Override
	public <T, E extends Throwable> T accept(PGoTypeVisitor<T, E> v) throws E {
		return v.visit(this);
	}
}
