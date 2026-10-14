from uuid import NAMESPACE_URL, UUID, uuid5
import re

from .models import SyncInput

_HYPOTHETICAL = re.compile(
    r'\b(what if|if i eat|if i have|should i|what can i|how much|y si|si como|si comiera|voy a|qué ceno|que ceno|qué tiene|que tiene|qué puedo|que puedo|podría|podria|recomend)\b',
    re.IGNORECASE,
)


def is_hypothetical(text: str) -> bool:
    return bool(_HYPOTHETICAL.search(text))


def build_food_sync(operation_id: UUID, base_revision: int, foods) -> SyncInput:
    """Build one atomic, replayable sync operation for a batch of food entries."""
    operations = []
    for index, food in enumerate(foods):
        entry_id = uuid5(NAMESPACE_URL, f'food:{operation_id}' if index == 0 else f'food:{operation_id}:{index}')
        item_operation_id = operation_id if index == 0 else uuid5(NAMESPACE_URL, f'food-operation:{operation_id}:{index}')
        draft = food.to_draft() if hasattr(food, 'to_draft') else food.draft()
        operations.append({
            'operation_id': item_operation_id,
            'action': 'upsert',
            'kind': 'entry',
            'id': entry_id,
            'expected_version': 0,
            'payload': {'draft': draft.model_dump(mode='json')},
        })
    return SyncInput(
        request_id=uuid5(NAMESPACE_URL, 'plugin:'+str(operation_id)),
        base_revision=base_revision,
        operations=operations,
    )
