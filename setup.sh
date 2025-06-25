#!/bin/bash

# Get parameters from user data
DB_ENDPOINT=$1
DB_NAME=$2
DB_USERNAME=$3
DB_PASSWORD=$4

echo "Starting Todo App setup..."
echo "Database endpoint: $DB_ENDPOINT"

# Install Node.js 18
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
yum install -y nodejs

# Install PM2 for process management
npm install -g pm2

# Install CloudWatch agent
yum install -y amazon-cloudwatch-agent

# Create application directory
mkdir -p /opt/todo-app
cd /opt/todo-app

# Create package.json for Todo App
cat > package.json << 'EOF'
{
  "name": "todo-app-backend",
  "version": "1.0.0",
  "description": "Todo App Backend with Auto Scaling",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "nodemon server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "mysql2": "^3.6.0",
    "cors": "^2.8.5",
    "helmet": "^7.0.0",
    "morgan": "^1.10.0",
    "body-parser": "^1.20.2",
    "uuid": "^9.0.0"
  }
}
EOF

# Create the Express server with Todo API
cat > server.js << EOF
const express = require('express');
const mysql = require('mysql2/promise');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const bodyParser = require('body-parser');
const { v4: uuidv4 } = require('uuid');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'build')));

// Database configuration
const dbConfig = {
  host: '$DB_ENDPOINT'.split(':')[0],
  user: '$DB_USERNAME',
  password: '$DB_PASSWORD',
  database: '$DB_NAME',
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0
};

let pool;

// Initialize database connection
async function initDB() {
  try {
    pool = mysql.createPool(dbConfig);
    
    // Create todos table if not exists
    await pool.execute(\`
      CREATE TABLE IF NOT EXISTS todos (
        id VARCHAR(36) PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        description TEXT,
        completed BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        instance_id VARCHAR(255)
      )
    \`);
    
    // Create health_checks table
    await pool.execute(\`
      CREATE TABLE IF NOT EXISTS health_checks (
        id INT AUTO_INCREMENT PRIMARY KEY,
        instance_id VARCHAR(255),
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        status VARCHAR(50)
      )
    \`);
    
    console.log('Database connected successfully');
  } catch (error) {
    console.error('Database connection failed:', error);
  }
}

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    const instanceId = process.env.INSTANCE_ID || 'unknown';
    
    if (pool) {
      await pool.execute(
        'INSERT INTO health_checks (instance_id, status) VALUES (?, ?)',
        [instanceId, 'healthy']
      );
    }
    
    res.status(200).json({
      status: 'healthy',
      timestamp: new Date().toISOString(),
      instance: instanceId
    });
  } catch (error) {
    res.status(500).json({
      status: 'unhealthy',
      error: error.message
    });
  }
});

// API Routes for Todo App
// Get all todos
app.get('/api/todos', async (req, res) => {
  try {
    const [rows] = await pool.execute('SELECT * FROM todos ORDER BY created_at DESC');
    res.json(rows);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Get single todo
app.get('/api/todos/:id', async (req, res) => {
  try {
    const [rows] = await pool.execute('SELECT * FROM todos WHERE id = ?', [req.params.id]);
    if (rows.length === 0) {
      return res.status(404).json({ error: 'Todo not found' });
    }
    res.json(rows[0]);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Create new todo
app.post('/api/todos', async (req, res) => {
  try {
    const { title, description } = req.body;
    const id = uuidv4();
    const instanceId = process.env.INSTANCE_ID || 'unknown';
    
    await pool.execute(
      'INSERT INTO todos (id, title, description, instance_id) VALUES (?, ?, ?, ?)',
      [id, title, description, instanceId]
    );
    
    const [rows] = await pool.execute('SELECT * FROM todos WHERE id = ?', [id]);
    res.status(201).json(rows[0]);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Update todo
app.put('/api/todos/:id', async (req, res) => {
  try {
    const { title, description, completed } = req.body;
    
    await pool.execute(
      'UPDATE todos SET title = ?, description = ?, completed = ? WHERE id = ?',
      [title, description, completed, req.params.id]
    );
    
    const [rows] = await pool.execute('SELECT * FROM todos WHERE id = ?', [req.params.id]);
    if (rows.length === 0) {
      return res.status(404).json({ error: 'Todo not found' });
    }
    
    res.json(rows[0]);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Delete todo
app.delete('/api/todos/:id', async (req, res) => {
  try {
    const [result] = await pool.execute('DELETE FROM todos WHERE id = ?', [req.params.id]);
    if (result.affectedRows === 0) {
      return res.status(404).json({ error: 'Todo not found' });
    }
    res.json({ message: 'Todo deleted successfully' });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Toggle todo completion
app.patch('/api/todos/:id/toggle', async (req, res) => {
  try {
    await pool.execute(
      'UPDATE todos SET completed = NOT completed WHERE id = ?',
      [req.params.id]
    );
    
    const [rows] = await pool.execute('SELECT * FROM todos WHERE id = ?', [req.params.id]);
    if (rows.length === 0) {
      return res.status(404).json({ error: 'Todo not found' });
    }
    
    res.json(rows[0]);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Status endpoint
app.get('/api/status', (req, res) => {
  res.json({
    message: 'Todo App API is running!',
    timestamp: new Date().toISOString(),
    instance: process.env.INSTANCE_ID || 'unknown'
  });
});

// Serve simple frontend
app.get('*', (req, res) => {
  res.send(\`
    <!DOCTYPE html>
    <html>
    <head>
        <title>Todo App - AWS Auto Scaling</title>
        <style>
            body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
            .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 10px; text-align: center; margin-bottom: 20px; }
            .todo-form { background: #f5f5f5; padding: 20px; border-radius: 10px; margin-bottom: 20px; }
            .todo-item { background: white; border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 5px; }
            .btn { background: #667eea; color: white; border: none; padding: 10px 15px; border-radius: 5px; cursor: pointer; margin: 5px; }
            .btn:hover { background: #5a6fd8; }
            input, textarea { width: 100%; padding: 10px; margin: 5px 0; border: 1px solid #ddd; border-radius: 5px; }
        </style>
    </head>
    <body>
        <div class="header">
            <h1>📝 Todo App</h1>
            <p>AWS Auto Scaling Web Application</p>
            <p>Instance: \${process.env.INSTANCE_ID || 'unknown'}</p>
        </div>
        
        <div class="todo-form">
            <h3>Add New Todo</h3>
            <input type="text" id="title" placeholder="Todo title" required>
            <textarea id="description" placeholder="Description" rows="3"></textarea>
            <button class="btn" onclick="addTodo()">Add Todo</button>
        </div>
        
        <div id="todos"></div>
        
        <script>
            async function loadTodos() {
                try {
                    const response = await fetch('/api/todos');
                    const todos = await response.json();
                    const todosDiv = document.getElementById('todos');
                    todosDiv.innerHTML = todos.map(todo => \\\`
                        <div class="todo-item">
                            <h4>\\\${todo.title}</h4>
                            <p>\\\${todo.description || ''}</p>
                            <p>Status: \\\${todo.completed ? 'Completed' : 'Pending'}</p>
                            <p>Instance: \\\${todo.instance_id}</p>
                            <button class="btn" onclick="toggleTodo('\\\${todo.id}')">\\\${todo.completed ? 'Mark Pending' : 'Mark Complete'}</button>
                            <button class="btn" onclick="deleteTodo('\\\${todo.id}')">Delete</button>
                        </div>
                    \\\`).join('');
                } catch (error) {
                    console.error('Error loading todos:', error);
                }
            }
            
            async function addTodo() {
                const title = document.getElementById('title').value;
                const description = document.getElementById('description').value;
                if (!title) return;
                
                try {
                    await fetch('/api/todos', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ title, description })
                    });
                    document.getElementById('title').value = '';
                    document.getElementById('description').value = '';
                    loadTodos();
                } catch (error) {
                    console.error('Error adding todo:', error);
                }
            }
            
            async function toggleTodo(id) {
                try {
                    await fetch(\\\`/api/todos/\\\${id}/toggle\\\`, { method: 'PATCH' });
                    loadTodos();
                } catch (error) {
                    console.error('Error toggling todo:', error);
                }
            }
            
            async function deleteTodo(id) {
                try {
                    await fetch(\\\`/api/todos/\\\${id}\\\`, { method: 'DELETE' });
                    loadTodos();
                } catch (error) {
                    console.error('Error deleting todo:', error);
                }
            }
            
            // Load todos on page load
            loadTodos();
            setInterval(loadTodos, 30000); // Refresh every 30 seconds
        </script>
    </body>
    </html>
  \`);
});

// Start server
app.listen(PORT, async () => {
  console.log(\`Todo App server running on port \${PORT}\`);
  await initDB();
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  if (pool) {
    pool.end();
  }
  process.exit(0);
});
EOF

# Install dependencies
npm install

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
export INSTANCE_ID

# Start the application with PM2
pm2 start server.js --name "todo-app"
pm2 startup
pm2 save

# Configure CloudWatch agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "metrics": {
    "namespace": "CWAgent",
    "metrics_collected": {
      "cpu": {
        "measurement": [
          "cpu_usage_idle",
          "cpu_usage_iowait",
          "cpu_usage_user",
          "cpu_usage_system"
        ],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": [
          "used_percent"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "*"
        ]
      },
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/aws/ec2/todo-app",
            "log_stream_name": "{instance_id}/messages"
          }
        ]
      }
    }
  }
}
EOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

echo "Todo App setup completed successfully!"
