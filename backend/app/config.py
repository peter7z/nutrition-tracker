import os
import math
from dataclasses import dataclass

@dataclass(frozen=True)
class Settings:
    database: str = os.getenv('NUTRITION_DATABASE', './data/nutrition.sqlite3')
    environment: str = os.getenv('NUTRITION_ENV', 'development')
    openai_key: str = os.getenv('OPENAI_API_KEY', '')
    model: str = os.getenv('OPENAI_MODEL', '')
    input_price: float = float(os.getenv('AI_INPUT_USD_PER_MILLION', '0'))
    output_price: float = float(os.getenv('AI_OUTPUT_USD_PER_MILLION', '0'))
    daily_budget: float = float(os.getenv('AI_USER_DAILY_BUDGET_USD', '0.50'))
    global_budget: float = float(os.getenv('AI_GLOBAL_DAILY_BUDGET_USD', '5'))
    timeout: float = float(os.getenv('AI_TIMEOUT_SECONDS', '30'))
    requests_per_hour: int = int(os.getenv('AI_REQUESTS_PER_USER_HOUR', '30'))
    max_output_tokens: int = int(os.getenv('AI_MAX_OUTPUT_TOKENS', '1800'))
    auth_per_minute: int = int(os.getenv('AUTH_REQUESTS_PER_MINUTE', '10'))
    session_days: int = 30

    def __post_init__(self):
        numeric=(self.input_price,self.output_price,self.daily_budget,self.global_budget,self.timeout)
        if not all(math.isfinite(v) and v>=0 for v in numeric) or not 1<=self.timeout<=120:
            raise ValueError('Invalid finite budget/timeout configuration')
        if not 16<=self.max_output_tokens<=8000 or not 1<=self.requests_per_hour<=1000 or not 1<=self.auth_per_minute<=1000:
            raise ValueError('Invalid request/output limits')
        if self.environment not in ('development','test','production'): raise ValueError('Invalid environment')
