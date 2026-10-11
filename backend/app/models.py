from datetime import date, datetime
from typing import Any, Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
import math

class StrictModel(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)

class AuthInput(StrictModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=12, max_length=256)
    @field_validator('email')
    @classmethod
    def email_valid(cls, v):
        v = v.strip().lower()
        if '@' not in v or any(c.isspace() for c in v): raise ValueError('invalid email')
        return v

class Nutrition(StrictModel):
    energy: float | None = Field(default=None,ge=0,le=1000000)
    protein: float | None = Field(default=None,ge=0,le=1000000)
    carbohydrates: float | None = Field(default=None,ge=0,le=1000000)
    fat: float | None = Field(default=None,ge=0,le=1000000)
    saturatedFat: float | None = Field(default=None,ge=0,le=1000000)
    fiber: float | None = Field(default=None,ge=0,le=1000000)
    @field_validator('*', mode='before')
    @classmethod
    def numeric(cls,v):
        if v is not None and (isinstance(v,bool) or not isinstance(v,(int,float))): raise ValueError('numeric value required')
        return v

class Conversion(StrictModel):
    gramsPerServing: float | None = Field(default=None,gt=0,le=1000000)
    millilitersPerServing: float | None = Field(default=None,gt=0,le=1000000)
    gramsPerMilliliter: float | None = Field(default=None,gt=0,le=1000)
    @field_validator('*',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)

class EntryDraft(StrictModel):
    name: str = Field(min_length=1,max_length=500)
    mealName: str = Field(min_length=1,max_length=500)
    consumedAt: datetime
    amount: float = Field(gt=0,le=1000000)
    unit: Literal['gram','milliliter','serving']
    preparation: Literal['unspecified','raw','cooked']
    nutrition: Nutrition
    basis: Literal['per100Grams','per100Milliliters','perServing']
    conversion: Conversion | None = None
    source: Literal['manual','label','catalog','estimate','recipe']
    notes: str = Field(default='',max_length=20000)
    productID: UUID | None = None
    productVersion: int | None = Field(default=None,ge=1,strict=True)
    recipeID: UUID | None = None
    recipeVersion: int | None = Field(default=None,ge=1,strict=True)
    @field_validator('amount',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)
    @field_validator('consumedAt')
    @classmethod
    def timezone(cls,v):
        if v.tzinfo is None: raise ValueError('timezone required')
        return v
    @model_validator(mode='after')
    def convertible(self):
        factor=self.multiplier()
        if not math.isfinite(factor) or factor<=0: raise ValueError('invalid conversion')
        for value in self.nutrition.model_dump().values():
            if value is not None and (not math.isfinite(value*factor) or value*factor>1000000): raise ValueError('scaled nutrient too large')
        return self
    def multiplier(self):
        c = self.conversion or Conversion()
        if self.basis=='per100Grams':
            if self.unit=='gram': return self.amount/100
            if self.unit=='serving' and c.gramsPerServing: return self.amount*c.gramsPerServing/100
            if self.unit=='milliliter' and c.gramsPerMilliliter: return self.amount*c.gramsPerMilliliter/100
        if self.basis=='per100Milliliters':
            if self.unit=='milliliter': return self.amount/100
            if self.unit=='serving' and c.millilitersPerServing: return self.amount*c.millilitersPerServing/100
            if self.unit=='gram' and c.gramsPerMilliliter: return self.amount/c.gramsPerMilliliter/100
        if self.basis=='perServing':
            if self.unit=='serving': return self.amount
            if self.unit=='gram' and c.gramsPerServing: return self.amount/c.gramsPerServing
            if self.unit=='milliliter' and c.millilitersPerServing: return self.amount/c.millilitersPerServing
        raise ValueError('explicit conversion required')

class Operation(StrictModel):
    operation_id: UUID
    action: Literal['upsert','delete']
    kind: Literal['entry','day','goal','product','recipe','weight','activity','import','profile','historical','resolution']
    id: UUID
    expected_version: int = Field(ge=0,strict=True)
    payload: dict[str,Any] = Field(default_factory=dict)

class SyncInput(StrictModel):
    request_id: UUID
    base_revision: int = Field(ge=0,strict=True)
    operations: list[Operation] = Field(min_length=1,max_length=200)

class HealthContext(StrictModel):
    consent: Literal[True]
    purpose: Literal['chat','weekly_review']
    day: date
    metrics: dict[Literal['weight_kg','active_kcal','steps','exercise_minutes','dietary_kcal','protein_g','carbohydrates_g','fat_g'],float]
    @field_validator('consent',mode='before')
    @classmethod
    def explicit_bool(cls,v):
        if v is not True: raise ValueError('explicit consent required')
        return v
    @field_validator('metrics',mode='before')
    @classmethod
    def metric_numbers(cls,v):
        if not isinstance(v,dict) or any(isinstance(n,bool) or not isinstance(n,(int,float)) or not math.isfinite(n) or n<0 for n in v.values()): raise ValueError('invalid health metrics')
        return v

class ReviewWeight(StrictModel):
    day: date
    kilograms: float = Field(gt=0,le=1000)
    @field_validator('kilograms',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)

class ReviewNutrition(Nutrition):
    day: date
    saturatedFat: None = None

class ReviewActivity(StrictModel):
    day: date
    exercise_minutes: float | None = Field(default=None,ge=0,le=1440)
    active_kcal: float | None = Field(default=None,ge=0,le=1000000)
    @field_validator('exercise_minutes','active_kcal',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)

class HealthReviewContext(StrictModel):
    consent: Literal[True]
    purpose: Literal['weekly_review']
    start_day: date
    end_day: date
    weights: list[ReviewWeight] = Field(default_factory=list,max_length=14)
    daily_nutrition: list[ReviewNutrition] = Field(default_factory=list,max_length=14)
    daily_activity: list[ReviewActivity] = Field(default_factory=list,max_length=14)
    @field_validator('consent',mode='before')
    @classmethod
    def consent_required(cls,v): return HealthContext.explicit_bool(v)
    @model_validator(mode='after')
    def scope(self):
        if (self.end_day-self.start_day).days!=13: raise ValueError('fourteen day window required')
        for values in (self.weights,self.daily_nutrition,self.daily_activity):
            days=[v.day for v in values]
            if len(set(days))!=len(days) or any(d<self.start_day or d>self.end_day for d in days): raise ValueError('invalid summary scope')
        return self

class GoalProposal(StrictModel):
    energy: float | None = Field(default=None,gt=0,le=1000000)
    protein: float | None = Field(default=None,gt=0,le=1000000)
    carbohydrates: float | None = Field(default=None,gt=0,le=1000000)
    fat: float | None = Field(default=None,gt=0,le=1000000)
    effective_day: date
    rationale: str = Field(min_length=1,max_length=5000)
    assumptions: list[str] = Field(max_length=20)
    requires_confirmation: Literal[True]
    @field_validator('requires_confirmation',mode='before')
    @classmethod
    def confirmation(cls,v): return HealthContext.explicit_bool(v)
    @field_validator('energy','protein','carbohydrates','fat',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)
    @model_validator(mode='after')
    def has_goal(self):
        if all(getattr(self,n) is None for n in ('energy','protein','carbohydrates','fat')): raise ValueError('goal required')
        return self

class ChatInput(StrictModel):
    request_id: UUID
    day: date
    text: str = Field(min_length=1,max_length=5000)
    health_context: HealthContext | None = None
    health_review_context: HealthReviewContext | None = None
    attachment_id: UUID | None = None

class Proposal(StrictModel):
    operation_id: UUID
    action: Literal['add','update','delete','query','close_day','add_weight','add_activity']
    entry_id: UUID | None
    expected_version: int | None = Field(ge=0,strict=True)
    name: str | None
    quantity: float | None = Field(gt=0,le=1000000)
    unit: Literal['gram','milliliter','serving'] | None
    state: Literal['unspecified','raw','cooked'] | None
    day: date
    nutrients: Nutrition | None
    @field_validator('quantity',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)
    product_id: UUID | None = None
    product_version: int | None = Field(default=None,ge=1,strict=True)
    recipe_id: UUID | None = None
    recipe_version: int | None = Field(default=None,ge=1,strict=True)
    weight_kg: float | None = Field(default=None,gt=0,le=1000)
    recorded_at: datetime | None = None
    activity_kind: str | None = Field(default=None,min_length=1,max_length=500)
    duration_minutes: float | None = Field(default=None,ge=0,le=1440)
    active_kcal: float | None = Field(default=None,ge=0,le=1000000)
    @field_validator('weight_kg','duration_minutes','active_kcal',mode='before')
    @classmethod
    def metric_numeric(cls,v): return Nutrition.numeric(v)
    @field_validator('recorded_at')
    @classmethod
    def timestamp(cls,v): return EntryDraft.timezone(v) if v is not None else v
    assumptions: list[str] = Field(max_length=20)
    requires_clarification: bool

class AssistantOutput(StrictModel):
    message: str = Field(min_length=1,max_length=12000)
    intent: Literal['consumed','hypothetical','query','correction','close','photo','label','weekly_review','weight','activity']
    goal_proposal: GoalProposal | None = None
    proposals: list[Proposal] = Field(max_length=20)

class Product(StrictModel):
    id: UUID
    version: int = Field(ge=1,strict=True)
    name: str = Field(min_length=1,max_length=500)
    brand: str = Field(default='',max_length=500)
    nutrition: Nutrition
    basis: Literal['per100Grams','per100Milliliters','perServing']
    conversion: Conversion | None = None
    source: Literal['manual','label','catalog','estimate','recipe'] = 'label'
    updatedAt: datetime

class Recipe(StrictModel):
    id: UUID
    version: int = Field(ge=1,strict=True)
    name: str = Field(min_length=1,max_length=500)
    ingredients: list[EntryDraft] = Field(min_length=1,max_length=1000)
    finalWeightGrams: float | None = Field(default=None,gt=0,le=1000000)
    servings: float | None = Field(default=None,gt=0,le=1000000)
    updatedAt: datetime
    @field_validator('finalWeightGrams','servings',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)
    @model_validator(mode='after')
    def yield_required(self):
        if self.finalWeightGrams is None and self.servings is None: raise ValueError('recipe yield required')
        return self

class Profile(StrictModel):
    timeZoneIdentifier: str = Field(default='America/Montevideo',max_length=100)
    preferences: str = Field(default='',max_length=20000)
    @field_validator('timeZoneIdentifier')
    @classmethod
    def known_zone(cls,v):
        from zoneinfo import ZoneInfo
        try: ZoneInfo(v)
        except Exception: raise ValueError('invalid time zone') from None
        return v

class Weight(StrictModel):
    id: UUID
    recordedAt: datetime
    kilograms: float = Field(gt=0,le=1000)
    source: Literal['manual','spreadsheet'] = 'manual'
    notes: str = Field(default='',max_length=20000)
    importBatchID: UUID | None = None
    @field_validator('kilograms',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)
    @field_validator('recordedAt')
    @classmethod
    def timestamp(cls,v): return EntryDraft.timezone(v)

class Activity(StrictModel):
    id: UUID
    recordedAt: datetime
    kind: str = Field(min_length=1,max_length=500)
    durationMinutes: float | None = Field(default=None,ge=0,le=1000000)
    activeEnergy: float | None = Field(default=None,ge=0,le=1000000)
    source: Literal['manual','spreadsheet'] = 'manual'
    notes: str = Field(default='',max_length=20000)
    importBatchID: UUID | None = None
    @field_validator('durationMinutes','activeEnergy',mode='before')
    @classmethod
    def numeric(cls,v): return Nutrition.numeric(v)
    @field_validator('recordedAt')
    @classmethod
    def timestamp(cls,v): return EntryDraft.timezone(v)

class Historical(StrictModel):
    id: UUID
    dayID: date
    nutrients: Nutrition
    isClosed: bool
    notes: str = Field(max_length=20000)
    importBatchID: UUID
    sourceRow: str = Field(max_length=20000)

class Resolution(StrictModel):
    dayID: date
    selection: Literal['manual','historical','health']
    createdByBatchID: UUID | None = None
    revisionID: UUID | None = None
