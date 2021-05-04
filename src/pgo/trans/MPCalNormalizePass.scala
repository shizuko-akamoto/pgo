package pgo.trans

import pgo.model.{DerivedSourceLocation, PGoError, Rewritable, SourceLocationInternal, Visitable}
import pgo.model.mpcal._
import pgo.model.pcal._
import pgo.model.tla._
import pgo.util.{Description, IdMap, MPCalPassUtils, NameCleaner}
import Description._

import scala.annotation.tailrec

object MPCalNormalizePass {
  @throws[PGoError]
  def apply(tlaModule: TLAModule, mpcalBlock: MPCalBlock): MPCalBlock = {
    var block: MPCalBlock = mpcalBlock

    // expand all PCal macros (not including archetypes + mapping macros)
    block = MPCalPassUtils.rewriteEachBody(block) { (body, lexicalScope) =>
      MPCalPassUtils.expandMacroCalls(body, lexicalScope)
    }
    // remove the now-expanded macros
    locally {
      val stableBlock = block // hax because decorateLike incorrectly uses this.type
      block = stableBlock.decorateLike(stableBlock.copy(macros = Nil).asInstanceOf[stableBlock.type])
    }

    // normalise label nesting, so all labels appear at the top level.
    // retain control flow by injecting synthetic gotos at label boundaries that use fall-through
    // do this as early as possible (minus PCal macros), as it helps other passes skip nested label-related edge cases:
    //   it is very useful to have the guarantee that some syntactically nested compound statement must be entirely
    //   within the same critical section (and, in some cases, to know that syntactically all sub-statements will not involve labels)
    block = locally {
      val containsLabels = MPCalPassUtils.gatherContainsLabels(block)

      MPCalPassUtils.rewriteEachBody(block) { (body, _) =>
        val labelCleaner = new NameCleaner
        body.foreach { stmt =>
          stmt.visit(Visitable.BottomUpFirstStrategy) {
            case PCalLabeledStatements(label, _) =>
              labelCleaner.addKnownName(label.name)
          }
        }

        def findLabelAfter(restStmts: List[PCalStatement], labelAfter: Option[PCalLabel]): Option[PCalLabel] =
          restStmts match {
            case Nil => labelAfter
            case PCalLabeledStatements(label, _) :: _ => Some(label)
            case _ => None
          }

        @tailrec
        def transBlocks(blocks: List[PCalLabeledStatements], labelAfter: Option[PCalLabel], blocksOut: Iterator[PCalLabeledStatements]): Iterator[PCalLabeledStatements] =
          blocks match {
            case Nil => blocksOut
            case (labeledStmts @PCalLabeledStatements(whileLabel, (whileStmt @PCalWhile(whileCondition, whileBody)) :: afterWhileStmts)) :: restBlocks =>
              val (whileBodyTrans, whileBodyBlocks) = impl(whileBody, Some(whileLabel), Iterator.empty, Iterator.empty)
              val (afterWhileTrans, afterWhileBlocks) = impl(afterWhileStmts, findLabelAfter(restBlocks, labelAfter), Iterator.empty, Iterator.empty)
              val whileTrans = whileStmt.withChildren(Iterator(whileCondition, whileBodyTrans))
              val labeledStmtsTrans = labeledStmts.withChildren(Iterator(whileLabel, whileTrans :: afterWhileTrans))
              transBlocks(restBlocks, labelAfter, blocksOut ++ Iterator.single(labeledStmtsTrans) ++ whileBodyBlocks ++ afterWhileBlocks)
            case (labeledStmts @PCalLabeledStatements(label, stmts)) :: restBlocks =>
              val (stmtsTrans, stmtsBlocks) = impl(stmts, findLabelAfter(restBlocks, labelAfter), Iterator.empty, Iterator.empty)
              val labeledTrans = labeledStmts.withChildren(Iterator(label, stmtsTrans))
              transBlocks(restBlocks, labelAfter, blocksOut ++ Iterator.single(labeledTrans) ++ stmtsBlocks)
          }

        def transStmt(stmt: PCalStatement, labelAfter: Option[PCalLabel]): (PCalStatement, Iterator[PCalLabeledStatements]) =
          stmt match {
            case stmt @PCalEither(cases) =>
              val casesTrans = cases.map(impl(_, labelAfter, Iterator.empty, Iterator.empty))
              (stmt.withChildren(Iterator(casesTrans.map(_._1))), casesTrans.iterator.flatMap(_._2))
            case stmt @PCalIf(condition, yes, no) =>
              val (yesTrans, yesBlocks) = impl(yes, labelAfter, Iterator.empty, Iterator.empty)
              val (noTrans, noBlocks) = impl(no, labelAfter, Iterator.empty, Iterator.empty)
              (stmt.withChildren(Iterator(condition, yesTrans, noTrans)), yesBlocks ++ noBlocks)
            case PCalLabeledStatements(label, statements) => ??? // should be inaccessible; handled via other cases
            case stmt @PCalWhile(condition, body) =>
              val (bodyTrans, bodyBlocks) = impl(body, labelAfter, Iterator.empty, Iterator.empty)
              (stmt.withChildren(Iterator(condition, bodyTrans)), bodyBlocks)
            case stmt @PCalWith(variables, body) =>
              val (bodyTrans, bodyBlocks) = impl(body, labelAfter, Iterator.empty, Iterator.empty)
              assert(bodyBlocks.isEmpty)
              (stmt.withChildren(Iterator(variables, bodyTrans)), Iterator.empty)
            case stmt => (stmt, Iterator.empty)
          }

        @tailrec
        def impl(stmts: List[PCalStatement], labelAfter: Option[PCalLabel], stmtsOut: Iterator[PCalStatement], blocksOut: Iterator[PCalLabeledStatements]): (List[PCalStatement],Iterator[PCalLabeledStatements]) = {
          object ContainsJump {
            def unapply(stmts: List[PCalStatement]): Option[(List[PCalStatement],List[PCalStatement])] =
              stmts match {
                case (goto: PCalGoto) :: restBlocks => Some((List(goto), restBlocks))
                case (ifStmt: PCalIf) :: restBlocks if containsLabels(ifStmt) => Some((List(ifStmt), restBlocks))
                case (either: PCalEither) :: restBlocks if containsLabels(either) => Some((List(either), restBlocks))

                case (call: PCalCall) :: (ret: PCalReturn) :: restBlocks => Some((List(call, ret), restBlocks))
                case (call: PCalCall) :: (goto: PCalGoto) :: restBlocks => Some((List(call, goto), restBlocks))
                case (call: PCalCall) :: restBlocks => Some((List(call), restBlocks))

                case (mpCall @PCalExtensionStatement(_: MPCalCall)) :: (ret: PCalReturn) :: restBlocks => Some((List(mpCall, ret), restBlocks))
                case (mpCall @PCalExtensionStatement(_: MPCalCall)) :: (goto: PCalGoto) :: restBlocks => Some((List(mpCall, goto), restBlocks))
                case (mpCall @PCalExtensionStatement(_: MPCalCall)) :: restBlocks => Some((List(mpCall), restBlocks))

                case _ => None
              }
          }

          stmts match {
            case Nil =>
              val synthJump = labelAfter.map(label => PCalGoto(label.name).setSourceLocation(DerivedSourceLocation(label.sourceLocation, SourceLocationInternal, d"tail-call transformation")))
              ((stmtsOut ++ synthJump.iterator).toList, blocksOut)
            case allBlocks @PCalLabeledStatements(_, _) :: _ =>
              assert(allBlocks.forall(_.isInstanceOf[PCalLabeledStatements]))
              (stmtsOut.toList, transBlocks(allBlocks.asInstanceOf[List[PCalLabeledStatements]], labelAfter, blocksOut))
            case ContainsJump(jumpStmts, restStmts) =>
              assert(restStmts.forall(_.isInstanceOf[PCalLabeledStatements]))
              val jumpTrans = jumpStmts.map(transStmt(_, findLabelAfter(restStmts, labelAfter)))
              ((stmtsOut ++ jumpTrans.iterator.map(_._1)).toList,
                transBlocks(restStmts.asInstanceOf[List[PCalLabeledStatements]], labelAfter, blocksOut ++ jumpTrans.iterator.flatMap(_._2)))
            case stmt :: restStmts =>
              val (stmtTrans, stmtBlocks) = transStmt(stmt, findLabelAfter(restStmts, labelAfter))
              impl(restStmts, labelAfter, stmtsOut ++ Iterator.single(stmtTrans), blocksOut ++ stmtBlocks)
          }
        }

        body match {
          case PCalLabeledStatements(_, _) :: _ =>
            assert(body.forall(_.isInstanceOf[PCalLabeledStatements]))
            transBlocks(body.asInstanceOf[List[PCalLabeledStatements]], None, Iterator.empty).toList
          case _ =>
            assert(body.forall(!containsLabels(_)))
            body
        }

      }
    }

    // desugar while loops into ifs and gotos
    // note: the statements after the while go inside the _else branch_, as evidenced by a label not being needed
    //       after a label-containing while statement (if it were equivalent to an if with statements after it, a label would be needed)
    block = block.rewrite(Rewritable.BottomUpOnceStrategy) {
      case labeledStmts @PCalLabeledStatements(label, (whileStmt @PCalWhile(condition, body)) :: restStmts) =>
        PCalLabeledStatements(
          label,
          List(PCalIf(
            condition,
            body :+ PCalGoto(label.name).setSourceLocation(whileStmt.sourceLocation.derivedVia(d"while statement desugaring")),
            restStmts).setSourceLocation(whileStmt.sourceLocation.derivedVia(d"while statement desugaring")))
        ).setSourceLocation(labeledStmts.sourceLocation)
    }

    // needed below: gather all names, to generate synthetic ones for multiple assignment temp vars
    val nameCleaner = new NameCleaner
    MPCalPassUtils.forEachName(tlaModule, block)(nameCleaner.addKnownName)
    block.visit(Visitable.BottomUpFirstStrategy) {
      case ident: TLAIdentifier => nameCleaner.addKnownName(ident.id)
    }

    // desugar multiple assignment into single assignment, using a with statement to ensure correct order of operations
    block = block.rewrite(Rewritable.BottomUpOnceStrategy) {
      case assignment @PCalAssignment(pairs) if pairs.size > 1 =>
        @tailrec
        def lhsIdentifier(lhs: PCalAssignmentLhs): PCalAssignmentLhsIdentifier =
          lhs match {
            case ident @PCalAssignmentLhsIdentifier(_) => ident
            case PCalAssignmentLhsProjection(lhs, _) => lhsIdentifier(lhs)
          }
        val bindings = pairs.map {
          case pair @PCalAssignmentPair(lhs, rhs) =>
            val lhsIdent = lhsIdentifier(lhs)
            val lhsName = nameCleaner.cleanName(lhsIdent.identifier.id)
            val decl = PCalVariableDeclarationValue(
              TLAIdentifier(lhsName)
                .setSourceLocation(lhsIdent.sourceLocation.derivedVia(d"multiple-assignment desugaring")),
              rhs)
              .setSourceLocation(pair.sourceLocation.derivedVia(d"multiple-assignment desugaring"))
            (lhsIdent.refersTo, decl)
        }
        val refMap = bindings.to(IdMap)
        PCalWith(bindings.map(_._2), pairs.map {
          case pair @PCalAssignmentPair(lhs, rhs) =>
            def applyRenamings[T <: Rewritable](rewritable: T): T =
              rewritable.rewrite(Rewritable.BottomUpOnceStrategy) {
                case ident: TLAGeneralIdentifier if refMap.contains(ident.refersTo) =>
                  val defn = refMap(ident.refersTo)
                  val loc = ident.sourceLocation.derivedVia(d"multiple-assignment desugaring")
                  TLAGeneralIdentifier(defn.name.shallowCopy().setSourceLocation(loc), Nil)
                    .setSourceLocation(loc)
                    .setRefersTo(defn)
              }

            def applyRenamingsToLhs(lhs: PCalAssignmentLhs): PCalAssignmentLhs =
              lhs match {
                case ident @PCalAssignmentLhsIdentifier(_) => ident
                case proj @PCalAssignmentLhsProjection(lhs, projections) =>
                  proj.withChildren(Iterator(applyRenamingsToLhs(lhs), projections.mapConserve(applyRenamings)))
              }

            PCalAssignment(List(PCalAssignmentPair(applyRenamingsToLhs(lhs), applyRenamings(rhs))))
              .setSourceLocation(pair.sourceLocation.derivedVia(d"multiple-assignment desugaring"))
        })
          .setSourceLocation(assignment.sourceLocation.derivedVia(d"multiple-assignment desugaring"))
    }

    block
  }
}
